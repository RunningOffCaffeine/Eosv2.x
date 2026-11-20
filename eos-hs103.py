#!/usr/bin/env python3
"""EOS: manage an HS103's ON-PLUG OFF countdown over its legacy LAN API.

Never sends set_relay_state/off. The Pi may share power with this plug.
Intentionally refuses unfamiliar devices/firmware/timer rules.
"""
import argparse
import ipaddress
import json
import os
import socket
import struct
import sys

NAME = 'EOS_SAFE_OFF'
PORT = 9999
TIMEOUT = 5

class Unsafe(Exception):
    pass


def recv_exact(sock, count):
    chunks = bytearray()
    while len(chunks) < count:
        part = sock.recv(count - len(chunks))
        if not part:
            raise Unsafe('HS103 closed connection before reply was complete')
        chunks.extend(part)
    return bytes(chunks)


def crypt(data, decrypt=False):
    key = 0xAB
    result = bytearray()
    for byte in data:
        if decrypt:
            result.append(byte ^ key)
            key = byte
        else:
            val = byte ^ key
            result.append(val)
            key = val
    return bytes(result)


class HS103:
    def __init__(self, host, delay, expected_mac):
        try:
            address = ipaddress.ip_address(host)
        except ValueError as exc:
            raise Unsafe('Set EOS_HS103_IP to the HS103 LAN IPv4 address') from exc
        if address.version != 4 or not (address.is_private or address.is_link_local):
            raise Unsafe('HS103 address must be a local/private IPv4 address')
        self.host = host
        self.delay = delay
        self.expected_mac = expected_mac.replace(':', '').replace('-', '').lower()

    def call(self, module, method, argument=None):
        raw = json.dumps({module: {method: argument}}, separators=(',', ':')).encode()
        request = struct.pack('>I', len(raw)) + crypt(raw)
        try:
            with socket.create_connection((self.host, PORT), TIMEOUT) as conn:
                conn.settimeout(TIMEOUT)
                conn.sendall(request)
                length = struct.unpack('>I', recv_exact(conn, 4))[0]
                if length > 1024 * 1024:
                    raise Unsafe('Implausibly long HS103 response')
                reply = json.loads(crypt(recv_exact(conn, length), decrypt=True))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise Unsafe(f'HS103 local API unavailable ({exc})') from exc
        result = reply.get(module, {}).get(method)
        if not isinstance(result, dict):
            raise Unsafe(f'HS103 did not return {module}.{method}: {reply}')
        if int(result.get('err_code', 0)) != 0:
            raise Unsafe(f'HS103 rejected {module}.{method}: {result}')
        return result

    def validate_device(self):
        info = self.call('system', 'get_sysinfo')
        model = str(info.get('model', ''))
        if not model.upper().startswith('HS103'):
            raise Unsafe(f'Expected HS103, but {self.host} reports {model!r}')
        if int(info.get('relay_state', -1)) != 1:
            raise Unsafe('HS103 outlet is not reporting ON')
        actual_mac = str(info.get('mac', '')).replace(':', '').replace('-', '').lower()
        if self.expected_mac and self.expected_mac != actual_mac:
            raise Unsafe('HS103 MAC differs from configured EOS_HS103_EXPECTED_MAC')
        return info

    def rules(self):
        result = self.call('count_down', 'get_rules')
        rules = result.get('rule_list')
        if not isinstance(rules, list):
            raise Unsafe('HS103 firmware did not report a countdown rule list')
        return rules

    def owned_rule(self, rules):
        if not rules:
            return None
        if len(rules) != 1 or str(rules[0].get('name', '')) != NAME:
            raise Unsafe('HS103 already has an unrelated countdown rule. Cancel it in the Kasa app first.')
        if not rules[0].get('id'):
            raise Unsafe('Countdown rule has no ID')
        return rules[0]

    def edit(self, rule_id, enable):
        return self.call('count_down', 'edit_rule', {
            'id': rule_id, 'enable': int(enable), 'delay': self.delay,
            'act': 0, 'name': NAME,
        })

    def cancel(self):
        rule = self.owned_rule(self.rules())
        if rule is None:
            print('[EOS HS103] No EOS countdown exists.')
            return
        self.edit(rule['id'], 0)
        after = self.owned_rule(self.rules())
        if not after or int(after.get('enable', -1)) != 0:
            raise Unsafe('Could not confirm HS103 timer cancellation! Check Kasa app immediately.')
        print('[EOS HS103] EOS countdown disabled and verified (outlet remains ON).')

    def arm(self):
        self.validate_device()
        rule = self.owned_rule(self.rules())
        if rule is not None and int(rule.get('enable', 0)):
            raise Unsafe('An EOS countdown is already active. Run --cancel before another OFF.')
        if rule is None:
            self.call('count_down', 'add_rule', {
                'enable': 0, 'delay': self.delay, 'act': 0, 'name': NAME,
            })
            rule = self.owned_rule(self.rules())
            if rule is None:
                raise Unsafe('HS103 did not retain the disabled EOS timer')
        try:
            self.edit(rule['id'], 1)
            confirmed = self.owned_rule(self.rules())
            if not confirmed or int(confirmed.get('enable', 0)) != 1 or int(confirmed.get('act', -1)) != 0:
                raise Unsafe('Could not verify an active OFF timer')
            remain = confirmed.get('remain')
            if remain is not None and int(remain) <= 0:
                raise Unsafe('Timer is active but has no time remaining')
        except Exception:
            # An edit may have taken effect even when its reply was lost.
            # Best effort rollback; if cancellation fails, the user must check the app.
            try:
                self.cancel()
            except Exception as cancel_error:
                print(f'[EOS HS103] URGENT: Timer state unknown, check Kasa app: {cancel_error}', file=sys.stderr)
            raise
        print(f'[EOS HS103] CONFIRMED: HS103 will switch OFF in ~{self.delay}s even after Pi shutdown.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'preflight', 'arm', 'cancel'])
    args = parser.parse_args()
    delay = int(os.environ.get('EOS_HS103_DELAY', '240'))
    if delay < 180 or delay > 900:
        raise Unsafe('EOS_HS103_DELAY must be 180..900 seconds (grace for OS shutdown)')
    plug = HS103(os.environ.get('EOS_HS103_IP', ''), delay,
                 os.environ.get('EOS_HS103_EXPECTED_MAC', ''))
    info = plug.validate_device()
    if args.action == 'status':
        print('[EOS HS103] Model: %s | IP: %s | Alias: %s' %
              (info.get('model', '?'), plug.host, info.get('alias', '?')))
        for rule in plug.rules():
            print('[EOS HS103] Countdown: ' + json.dumps(rule, sort_keys=True))
        return
    if args.action == 'preflight':
        rule = plug.owned_rule(plug.rules())
        if rule is not None and int(rule.get('enable', 0)) != 0:
            raise Unsafe('A countdown is already active. Cancel it before starting OFF.')
        print('[EOS HS103] Preflight OK: HS103 reachable, ON, and countdown available.')
    elif args.action == 'arm':
        plug.arm()
    else:
        plug.cancel()


if __name__ == '__main__':
    try:
        main()
    except (Unsafe, ValueError, TypeError) as error:
        print(f'[EOS HS103] ERROR: {error}', file=sys.stderr)
        sys.exit(1)
