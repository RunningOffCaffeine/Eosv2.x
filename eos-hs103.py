#!/usr/bin/env python3
"""EOS HS103 countdown helper (legacy local API, TCP 9999).

This tool NEVER directly switches the relay OFF. The HS103 powers the Pi itself.
Only a verified, device-resident countdown may be used for EOS shutdown.

Commands:
    status      inspect device and current rule (read-only)
    preflight   validate device and rule availability (read-only)
    probe       interactively arm a timer, verify it counts, then cancel it
    arm         arm a real OFF countdown (only for controlled OFF workflow)
    cancel      remove the EOS-owned countdown, leaving outlet ON
"""
import argparse
import ipaddress
import json
import os
import socket
import struct
import sys
import time

NAME = 'EOS_SAFE_OFF'
PLACEHOLDER_NAME = 'add timer'  # Left behind by the Kasa app after a timer ends.
PORT = 9999
TIMEOUT = 5
VERIFY_WAIT = 4


class Unsafe(Exception):
    pass


def recv_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise Unsafe('HS103 closed its response early')
        data.extend(chunk)
    return bytes(data)


def crypt(data, decrypt=False):
    key = 0xAB
    output = bytearray()
    for byte in data:
        if decrypt:
            output.append(byte ^ key)
            key = byte
        else:
            value = byte ^ key
            output.append(value)
            key = value
    return bytes(output)


class HS103:
    def __init__(self, host, delay, expected_mac=''):
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
                if not 0 < length < 1024 * 1024:
                    raise Unsafe('Invalid HS103 response length')
                response = json.loads(crypt(recv_exact(conn, length), decrypt=True))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise Unsafe(f'HS103 local API unavailable ({exc})') from exc
        result = response.get(module, {}).get(method)
        if not isinstance(result, dict):
            raise Unsafe(f'Malformed {module}.{method} response: {response}')
        if int(result.get('err_code', 0)) != 0:
            raise Unsafe(f'HS103 rejected {module}.{method}: {result}')
        return result

    def validate_device(self):
        info = self.call('system', 'get_sysinfo')
        model = str(info.get('model', ''))
        if not model.upper().startswith('HS103'):
            raise Unsafe(f'Expected HS103; device reported {model!r}')
        if int(info.get('relay_state', -1)) != 1:
            raise Unsafe('HS103 outlet is not ON')
        actual = str(info.get('mac', '')).replace(':', '').replace('-', '').lower()
        if self.expected_mac and actual != self.expected_mac:
            raise Unsafe('HS103 MAC does not match EOS_HS103_EXPECTED_MAC')
        return info

    def rules(self):
        result = self.call('count_down', 'get_rules')
        rules = result.get('rule_list')
        if not isinstance(rules, list):
            raise Unsafe('Firmware returned no valid countdown rule list')
        return rules

    def available_rule(self):
        """Permit empty table, own inactive rule, or Kasa app's empty placeholder."""
        rules = self.rules()
        if not rules:
            return None
        if len(rules) != 1:
            raise Unsafe('More than one countdown rule exists; refusing to replace any')
        rule = rules[0]
        if not rule.get('id'):
            raise Unsafe('Countdown rule is missing its ID')
        if int(rule.get('enable', -1)) != 0 or int(rule.get('remain', 0)) != 0:
            raise Unsafe('An existing countdown may be active. Cancel it in the Kasa app first')
        if str(rule.get('name', '')) not in (NAME, PLACEHOLDER_NAME):
            raise Unsafe('An unrelated saved countdown exists; refusing to replace it')
        return rule

    def owned_active(self):
        rules = self.rules()
        if len(rules) != 1 or str(rules[0].get('name', '')) != NAME:
            raise Unsafe('Expected exactly one EOS-owned countdown rule')
        rule = rules[0]
        if not rule.get('id'):
            raise Unsafe('EOS countdown lacks an ID')
        if int(rule.get('enable', -1)) != 1 or int(rule.get('act', -1)) != 0:
            raise Unsafe('EOS OFF countdown is not enabled with OFF action')
        if int(rule.get('delay', -1)) != self.delay:
            raise Unsafe('EOS countdown delay differs from configuration')
        remain = rule.get('remain')
        if remain is None:
            raise Unsafe('HS103 did not report remaining countdown time')
        remaining = int(remain)
        if not 0 < remaining <= self.delay:
            raise Unsafe(f'HS103 countdown remaining time is invalid: {remaining}')
        return rule, remaining

    def _delete_rule(self, rule_id):
        self.call('count_down', 'delete_rule', {'id': rule_id})
        if self.rules():
            raise Unsafe('HS103 rule deletion was not confirmed; check Kasa app')

    def cancel(self):
        rules = self.rules()
        if not rules:
            print('[EOS HS103] No countdown exists (outlet remains ON).')
            return
        if len(rules) != 1 or str(rules[0].get('name', '')) != NAME:
            raise Unsafe('Refusing to cancel a timer not owned by EOS')
        self._delete_rule(rules[0]['id'])
        print('[EOS HS103] EOS countdown removed and verified (outlet remains ON).')

    def arm(self):
        self.validate_device()
        old_rule = self.available_rule()
        if old_rule:
            # The Kasa app stores one inactive placeholder ('add timer') after
            # completion; remove it to make room for a fresh active timer.
            self._delete_rule(old_rule['id'])
        added_id = None
        try:
            answer = self.call('count_down', 'add_rule', {
                'enable': 1, 'delay': self.delay, 'act': 0, 'name': NAME,
            })
            added_id = answer.get('id')
            first, before = self.owned_active()
            if added_id and str(first['id']) != str(added_id):
                raise Unsafe('New countdown ID does not match device response')
            print(f'[EOS HS103] OFF countdown created: {before}s remaining.')
            time.sleep(VERIFY_WAIT)
            second, after = self.owned_active()
            if str(second['id']) != str(first['id']):
                raise Unsafe('Countdown rule ID changed during verification')
            if after >= before:
                raise Unsafe(f'Countdown is not decreasing ({before}s -> {after}s)')
            if before - after > VERIFY_WAIT + 20:
                raise Unsafe(f'Countdown jumped unexpectedly ({before}s -> {after}s)')
            self.validate_device()
            print(f'[EOS HS103] Verified running OFF countdown: {before}s -> {after}s.')
            print('[EOS HS103] Countdown verified locally; physical OFF after Pi shutdown still requires a supervised end-to-end test.')
        except BaseException:
            # A lost response or Ctrl-C can occur after activation: best-effort cancel.
            try:
                rules = self.rules()
                for rule in rules:
                    if str(rule.get('name', '')) == NAME or (added_id and str(rule.get('id')) == str(added_id)):
                        self._delete_rule(rule['id'])
                        print('[EOS HS103] Unverified EOS timer canceled.', file=sys.stderr)
            except Exception as exc:
                print(f'[EOS HS103] URGENT: Cannot confirm timer cancellation: {exc}. Check Kasa app immediately!', file=sys.stderr)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'preflight', 'arm', 'cancel', 'probe'])
    args = parser.parse_args()
    delay = int(os.environ.get('EOS_HS103_DELAY', '240'))
    if not 180 <= delay <= 900:
        raise Unsafe('EOS_HS103_DELAY must be between 180 and 900 seconds')
    plug = HS103(os.environ.get('EOS_HS103_IP', ''), delay,
                 os.environ.get('EOS_HS103_EXPECTED_MAC', ''))
    info = plug.validate_device()
    if args.action == 'status':
        print(f'[EOS HS103] Model: {info.get("model", "?")} | IP: {plug.host} | Alias: {info.get("alias", "?")}')
        for rule in plug.rules():
            print('[EOS HS103] Countdown: ' + json.dumps(rule, sort_keys=True))
    elif args.action == 'preflight':
        plug.available_rule()
        print('[EOS HS103] Preflight OK: plug ON; countdown slot available.')
    elif args.action == 'arm':
        plug.arm()
    elif args.action == 'cancel':
        plug.cancel()
    else:
        if not sys.stdin.isatty():
            raise Unsafe('Probe requires an interactive SSH terminal')
        plug.delay = 600  # Ten-minute safety window if probe cancellation fails.
        print('[EOS HS103] WARNING: Probe starts a REAL 600-second OFF timer.')
        print('[EOS HS103] It should cancel automatically after verification. If interrupted or cancellation fails, cancel in the Kasa app before ten minutes.')
        if input('Type TEST to proceed: ').strip() != 'TEST':
            print('[EOS HS103] Probe canceled; no timer armed.')
            return
        plug.arm()
        try:
            plug.cancel()
        except BaseException:
            print('[EOS HS103] URGENT: Check Kasa app immediately; probe timer may still be armed!', file=sys.stderr)
            raise
        print('[EOS HS103] PASS: OFF timer started, decreased, and was removed while Pi remained on.')


if __name__ == '__main__':
    try:
        main()
    except (Unsafe, ValueError, TypeError, KeyboardInterrupt) as exc:
        print(f'[EOS HS103] ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
