#!/usr/bin/env python3
"""Bridge a Level1Techs / Rextron HDMI 2.1 KVM's USB serial port to MQTT.

The KVM's AUX USB-C port enumerates as a CDC-ACM serial device (Artery AT32,
2e3c:5740). It takes text commands ending in CRLF (`V=2`), echoes them back and
prints a `>` prompt. There is no way to read the current state back, so the
state published here is the last thing this bridge (or Home Assistant) set.

Entities are announced through Home Assistant MQTT discovery.
"""

import json
import logging
import os
import pathlib
import queue
import signal
import threading
import time

import paho.mqtt.client as mqtt
import serial
from serial.tools import list_ports

MQTT_HOST = os.environ.get("MQTT_HOST", "mosquitto")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_USERNAME = os.environ.get("MQTT_USERNAME")
MQTT_PASSWORD = os.environ.get("MQTT_PASSWORD")
BASE_TOPIC = os.environ.get("BASE_TOPIC", "kvm")
DISCOVERY_PREFIX = os.environ.get("DISCOVERY_PREFIX", "homeassistant")
HA_STATUS_TOPIC = os.environ.get("HA_STATUS_TOPIC", "homeassistant/status")

SERIAL_PORT = os.environ.get("SERIAL_PORT")  # stable /dev/serial/by-id path; skips VID/PID detection
USB_VID = int(os.environ.get("USB_VID", "2e3c"), 16)
USB_PID = int(os.environ.get("USB_PID", "5740"), 16)
BAUD = int(os.environ.get("BAUD", "9600"))
CMD_TIMEOUT = float(os.environ.get("CMD_TIMEOUT", "2"))
PING_INTERVAL = float(os.environ.get("PING_INTERVAL", "30"))
# Probe files: ALIVE is touched every loop iteration, READY exists while MQTT and the KVM are both up.
ALIVE_FILE = pathlib.Path(os.environ.get("ALIVE_FILE", "/tmp/alive"))
READY_FILE = pathlib.Path(os.environ.get("READY_FILE", "/tmp/ready"))

AVAILABILITY_TOPIC = f"{BASE_TOPIC}/availability"
INPUTS = ["PC 1", "PC 2", "PC 3", "PC 4"]
FOLLOW = "Follow video"

log = logging.getLogger("kvm-controller")


def select_command(letter, option):
    """Map a select option to the KVM command, or None if it is not valid."""
    if option == FOLLOW and letter in ("A", "U"):
        return f"{letter}=*"
    if option in INPUTS:
        return f"{letter}={option[-1]}"
    return None


# key -> (component, name, icon, options, command builder)
ENTITIES = {
    "video": {
        "component": "select",
        "name": "Video Input",
        "icon": "mdi:monitor-multiple",
        "options": INPUTS,
        "command": lambda option: select_command("V", option),
    },
    "audio": {
        "component": "select",
        "name": "Audio Input",
        "icon": "mdi:speaker",
        "options": [FOLLOW] + INPUTS,
        "command": lambda option: select_command("A", option),
    },
    "usb": {
        "component": "select",
        "name": "USB Input",
        "icon": "mdi:usb-port",
        "options": [FOLLOW] + INPUTS,
        "command": lambda option: select_command("U", option),
    },
    "autoscan": {
        "component": "switch",
        "name": "Auto Scan",
        "icon": "mdi:sync",
        "command": lambda payload: {"ON": "V=A", "OFF": "V=$"}.get(payload),
    },
}


class KvmRejected(Exception):
    """The KVM is reachable but did not accept the command."""


class Kvm:
    """Serial link to the KVM. Every command is serialized under one lock."""

    def __init__(self):
        self._lock = threading.Lock()
        self._serial = None

    @staticmethod
    def _find_port():
        if SERIAL_PORT:
            return SERIAL_PORT if os.path.exists(SERIAL_PORT) else None
        for port in list_ports.comports():
            if port.vid == USB_VID and port.pid == USB_PID:
                return port.device
        return None

    def _open(self):
        device = self._find_port()
        if device is None:
            raise serial.SerialException("KVM serial device not found")
        self._serial = serial.Serial(device, BAUD, bytesize=8, parity="N", stopbits=1, timeout=0.2)
        log.info("opened %s", device)

    def close(self):
        with self._lock:
            self._close()

    def _close(self):
        if self._serial is not None:
            try:
                self._serial.close()
            except serial.SerialException:
                pass
            self._serial = None

    def send(self, command):
        """Send one command and return the reply text.

        The KVM ends every reply with a prompt line: `>` when the command was
        accepted, `<` when it was rejected (raises KvmRejected). Anything else,
        such as a timeout or an unplugged device, raises SerialException.
        """
        with self._lock:
            try:
                if self._serial is None:
                    self._open()
                self._serial.reset_input_buffer()
                self._serial.write(f"{command}\r\n".encode())
                self._serial.flush()
                reply = b""
                deadline = time.monotonic() + CMD_TIMEOUT
                while not reply.endswith((b"\n>\n", b"\n<\n")):
                    if time.monotonic() > deadline:
                        raise serial.SerialException(f"no prompt after {command!r}: {reply!r}")
                    reply += self._serial.read(256)
            except (serial.SerialException, OSError):
                self._close()
                raise
        text = reply.decode(errors="replace")
        if reply.endswith(b"\n<\n"):
            raise KvmRejected(f"{command!r} rejected: {text!r}")
        return text


class Bridge:
    def __init__(self):
        self.kvm = Kvm()
        self.commands = queue.Queue()
        self.stop = threading.Event()
        self.online = None
        self.connected = False
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"{BASE_TOPIC}-controller")
        if MQTT_USERNAME:
            self.client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
        self.client.will_set(AVAILABILITY_TOPIC, "offline", retain=True)
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message

    def publish(self, topic, payload, retain=True):
        return self.client.publish(topic, payload, retain=retain)

    def set_online(self, online):
        if online != self.online:
            self.online = online
            log.info("KVM %s", "online" if online else "offline")
            self.publish(AVAILABILITY_TOPIC, "online" if online else "offline")
            self.update_ready()

    def update_ready(self):
        if self.online and self.connected:
            READY_FILE.touch()
        else:
            READY_FILE.unlink(missing_ok=True)

    def publish_discovery(self):
        device = {
            "identifiers": [f"{BASE_TOPIC}_hdmi_kvm"],
            "name": "HDMI 2.1 KVM",
            "manufacturer": "Level1Techs / Rextron",
            "model": "HDMI 2.1 KVM w/EDID & Serial Control",
        }
        for key, entity in ENTITIES.items():
            config = {
                "name": entity["name"],
                "unique_id": f"{BASE_TOPIC}_{key}",
                "icon": entity["icon"],
                "command_topic": f"{BASE_TOPIC}/{key}/set",
                "state_topic": f"{BASE_TOPIC}/{key}/state",
                "availability_topic": AVAILABILITY_TOPIC,
                "device": device,
            }
            if entity["component"] == "select":
                config["options"] = entity["options"]
            topic = f"{DISCOVERY_PREFIX}/{entity['component']}/{BASE_TOPIC}_{key}/config"
            self.publish(topic, json.dumps(config))

    def on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            log.error("MQTT connect failed: %s", reason_code)
            return
        log.info("MQTT connected")
        self.connected = True
        client.subscribe([(f"{BASE_TOPIC}/{key}/set", 0) for key in ENTITIES] + [(HA_STATUS_TOPIC, 0)])
        self.publish_discovery()
        # Re-announce the real health; the broker may hold a stale "offline" from our last will.
        # Before the first ping there is nothing to announce yet, so skip rather than flap.
        if self.online is not None:
            online, self.online = self.online, None
            self.set_online(online)
        self.update_ready()

    def on_disconnect(self, client, userdata, flags, reason_code, properties):
        log.warning("MQTT disconnected: %s", reason_code)
        self.connected = False
        self.update_ready()

    def on_message(self, client, userdata, msg):
        payload = msg.payload.decode(errors="replace")
        if msg.topic == HA_STATUS_TOPIC:
            if payload == "online":
                self.publish_discovery()
            return
        key = msg.topic.split("/")[-2]
        if key in ENTITIES:
            self.commands.put((key, payload))

    def handle(self, key, payload):
        command = ENTITIES[key]["command"](payload)
        if command is None:
            log.warning("ignoring %r for %s", payload, key)
            return
        try:
            reply = self.kvm.send(command)
        except KvmRejected as err:
            log.error("%s", err)
            return
        except (serial.SerialException, OSError) as err:
            log.error("%s failed: %s", command, err)
            self.set_online(False)
            return
        log.info("%s -> %r", command, reply)
        self.set_online(True)
        self.publish(f"{BASE_TOPIC}/{key}/state", payload)
        # With auto scan on, the input changes on its own and we no longer know where it is.
        if key == "autoscan" and payload == "ON":
            self.publish(f"{BASE_TOPIC}/video/state", "None")

    def ping(self):
        try:
            self.kvm.send("")
            self.set_online(True)
        except KvmRejected:
            self.set_online(True)
        except (serial.SerialException, OSError) as err:
            log.warning("ping failed: %s", err)
            self.set_online(False)

    def run(self):
        self.client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=60)
        self.client.loop_start()
        next_ping = 0.0
        while not self.stop.is_set():
            ALIVE_FILE.touch()
            if time.monotonic() >= next_ping:
                self.ping()
                next_ping = time.monotonic() + (PING_INTERVAL if self.online else 5)
            try:
                key, payload = self.commands.get(timeout=1)
            except queue.Empty:
                continue
            self.handle(key, payload)
        self.publish(AVAILABILITY_TOPIC, "offline").wait_for_publish(timeout=2)
        self.client.loop_stop()
        self.client.disconnect()
        self.kvm.close()


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    bridge = Bridge()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: bridge.stop.set())
    bridge.run()


if __name__ == "__main__":
    main()
