#!/usr/bin/env python3
"""Apple Device Tree (ADT) codec + darwin-vm style fixup.

Format (little endian, confirmed against darwin-vm dt_fixup.py and UniXNU docs):

    node := u32 prop_count, u32 child_count,
            prop*, child*
    prop := char name[32] (NUL padded), u32 length, u8 value[length] (pad4)

Usage:
    python adt.py decode <adt.bin> [-o out.json]
    python adt.py encode <adt.json> -o <adt.bin>
    python adt.py fixup <in.adt> <out.adt> -nvram <nvram.bin> [--no-network]
    python adt.py selftest
"""
import argparse
import json
import math
import struct
import sys

SUPPORTED_DRIVERS = [b'AppleARM', b'aic', b'arm-io', b'uart-1,samsung']
FREQUENCY = 0x100000
IBOOT_NAME = 'qemu-sptm'
AMCC_BANK_STRIDE = 0x100
AMCC_LOWER_LIMIT_REG = 0x10
AMCC_UPPER_LIMIT_REG = 0x20
NUM_TUNNEL_DEVICES = 4
TUNNEL_DEVICE_PREFIX = 'qemuport'

# Errors are bitmasked so the C-style harness convention is preserved.
E_OK = 0
E_DECODE = 1 << 0
E_ENCODE = 1 << 1
E_ROUNDTRIP = 1 << 2
E_FIXUP = 1 << 3
E_SCHEMA = 1 << 4


def pad4(n):
    return 4 * math.ceil(n / 4)


def dec_str(b):
    return b.split(b'\0', 1)[0].decode('utf-8', 'replace')


def prop_text(value):
    """Logical text of a property regardless of retained metadata."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if 'str' in value:
            return value['str']
        if 'u32' in value:
            return str(value['u32'])
        if 'u64' in value:
            return str(value['u64'])
    return str(value)


def enc_str(s):
    return s.encode('utf-8') + b'\0'


def looks_like_string(b):
    if not b:
        return False
    parts = b.split(b'\0')
    if any(p != b'' for p in parts[1:]):
        return False
    try:
        text = b.decode('ascii').split('\0', 1)[0]
    except UnicodeDecodeError:
        return False
    return len(text) >= 3 and all(ch.isprintable() for ch in text)


class Node:
    def __init__(self, name=''):
        self.props = {}
        if name:
            self.props['name'] = name
        self.children = []

    def __getitem__(self, key):
        for child in self.children:
            if prop_text(child.props.get('name', '')) == key:
                return child
        raise KeyError(key)

    def __contains__(self, key):
        return any(prop_text(c.props.get('name', '')) == key for c in self.children)

    def add(self, child):
        self.children.append(child)
        return child

    def remove_child(self, name):
        for child in self.children:
            if prop_text(child.props.get('name', '')) == name:
                self.children.remove(child)
                return True
        return False

    def path(self, prefix=''):
        name = prop_text(self.props.get('name', ''))
        here = prefix + '/' + name if name else prefix
        out = {here[1:] if here else '': {k: v for k, v in self.props.items()}}
        for child in self.children:
            out.update(child.path(here))
        return out


def decode_prop(name, raw):
    if name == 'name' or looks_like_string(raw):
        return dec_str(raw)
    if len(raw) == 4:
        return {'u32': struct.unpack('<I', raw)[0]}
    if len(raw) == 8:
        return {'u64': struct.unpack('<Q', raw)[0]}
    return {'bytes': raw.hex()}


def decode_node(buf, off):
    if len(buf) - off < 8:
        raise ValueError('truncated node header')
    nprops, nchildren = struct.unpack_from('<II', buf, off)
    off += 8
    node = Node()
    for _ in range(nprops):
        if len(buf) - off < 36:
            raise ValueError('truncated property header')
        name = dec_str(buf[off:off + 32])
        raw_length = struct.unpack_from('<I', buf, off + 32)[0]
        present_bit = raw_length & 0x80000000
        length = raw_length & ~0x80000000
        padded = pad4(length)
        off += 36
        if len(buf) - off < padded:
            raise ValueError('truncated property value')
        value = buf[off:off + length]
        decoded = decode_prop(name, value)
        # Retain Apple's "present" flag and exact encoded length so a
        # decode->encode round trip is byte-identical, not just semantic.
        if isinstance(decoded, str):
            decoded = {'str': decoded, '_len': length, '_present': bool(present_bit)}
        elif isinstance(decoded, dict):
            decoded = dict(decoded)
            decoded['_present'] = bool(present_bit)
        node.props[name] = decoded
        off += padded
    for _ in range(nchildren):
        child, off = decode_node(buf, off)
        node.children.append(child)
    return node, off


def decode(data):
    root, consumed = decode_node(data, 0)
    if consumed != len(data):
        raise ValueError(f'trailing bytes: consumed {consumed}, total {len(data)}')
    return root


def encode_value(v):
    if isinstance(v, str):
        return enc_str(v) if v else b''
    if isinstance(v, dict):
        if '_len' in v and 'str' in v:
            # Exact original string length may include multiple trailing NULs.
            raw = enc_str(v['str'])
            target = v['_len']
            if len(raw) < target:
                raw = raw + b'\0' * (target - len(raw))
            return raw[:target] if len(raw) > target else raw
        if 'u32' in v:
            return struct.pack('<I', v['u32'])
        if 'u64' in v:
            return struct.pack('<Q', v['u64'])
        if 'bytes' in v:
            return bytes.fromhex(v['bytes'])
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return struct.pack('<I', int(v) & 0xffffffff)
    if v is None:
        return b''
    raise TypeError(f'unsupported property value: {v!r}')


def encode_node(node):
    out = bytearray(struct.pack('<II', len(node.props), len(node.children)))
    for key, value in node.props.items():
        name = key.encode('utf-8')
        if len(name) >= 32:
            raise ValueError(f'property name too long: {key}')
        raw = encode_value(value)
        present = value.get('_present', False) if isinstance(value, dict) else False
        out += name.ljust(32, b'\0')
        out += struct.pack('<I', len(raw) | (0x80000000 if present else 0))
        out += raw.ljust(pad4(len(raw)), b'\0')
    for child in node.children:
        out += encode_node(child)
    return bytes(out)


def encode(root):
    return encode_node(root)


def to_json(node):
    return {'props': node.props,
            'children': [{k: to_json(v) for k, v in child.to_json().items()}
                         for child in node.children]}


def to_json_obj(node):
    d = {'props': node.props, 'children': []}
    for child in node.children:
        d['children'].append({prop_text(child.props.get('name', 'unnamed')): to_json_obj(child)})
    return d


def from_json_obj(d):
    node = Node()
    node.props = d.get('props', {})
    for child in d.get('children', []):
        for name, sub in child.items():
            node.add(from_json_obj(sub))
    return node


def del_compat(node):
    for child in node.children:
        del_compat(child)
    if 'compatible' not in node.props:
        return
    compat = node.props['compatible']
    if isinstance(compat, str):
        compat = compat.encode('utf-8')
    elif isinstance(compat, dict):
        compat = json.dumps(compat).encode('utf-8')
    if not any(driver in compat for driver in SUPPORTED_DRIVERS):
        del node.props['compatible']


def fixup_aic(aic):
    compat = aic.props.get('compatible')
    if compat is None:
        raise KeyError("aic has no 'compatible' property")
    if isinstance(compat, str):
        compat = compat.encode('utf-8')
    elif isinstance(compat, dict):
        compat = json.dumps(compat).encode('utf-8')
    if b'aic,2' in compat or b'aic,3' in compat:
        aic.props['aic-iack-offset'] = {'u64': 0x1000}


MEMORY_MAP_KEYS = [
    'TXM-ro', 'TXM-rx', 'TXM-bx', 'TXM-rw', 'TXM-le', 'TXM-entry', 'TXM-virt',
    'TrustCache',
    'BootKC-rx', 'BootKC-bx', 'BootKC-ro', 'BootKC-rs', 'BootKC-rw',
    'BootKC-le', 'BootKC-virt', 'BootKC-entry',
    'DeviceTree',
    'SPTM-ro', 'SPTM-rm', 'SPTM-rx', 'SPTM-rw', 'SPTM-le', 'SPTM-entry', 'SPTM-virt',
    'BootArgs', 'slide',
    'CL4-rx', 'CL4-ro', 'CL4-rw', 'CL4-le', 'CL4-dummypage', 'CL4-entry',
    'CL4-virt',
    'RAMDisk',
]


def fixup_sptm(root):
    mmap = root['chosen']['memory-map']
    uninit = bytes.fromhex('ff' * 16)
    for key in MEMORY_MAP_KEYS:
        mmap.props[key] = {'bytes': uninit.hex()}
    mmap.props['slide'] = {'bytes': ('00' * 16)}
    root['arm-io'].remove_child('sgx')


def get_platform_name(root):
    compat = root['arm-io'].props['compatible']
    if isinstance(compat, dict):
        compat = json.dumps(compat)
    return str(compat).split(',')[1].rstrip("'\"") if ',' in str(compat) else str(compat)


def get_soc_gen(root):
    value = root['arm-io'].props.get('soc-generation')
    if not isinstance(value, str):
        return 0
    if not value.startswith('H'):
        return 0
    try:
        return int(value[1:])
    except ValueError:
        return 0


def copy_uart(uart0, index):
    new = Node()
    new.props['name'] = f'{TUNNEL_DEVICE_PREFIX}{index}'
    base, size = reg_pair(uart0.props['reg'])
    new.props['compatible'] = uart0.props['compatible']
    new.props['interrupt-parent'] = uart0.props['interrupt-parent']
    new.props['reg'] = {'bytes': struct.pack('<QQ', base + index * size, size).hex()}
    new.props['interrupts'] = {'u32': index}
    return new


def reg_pair(value):
    if isinstance(value, dict):
        raw = bytes.fromhex(value.get('bytes', ''))
        if len(raw) >= 16:
            return struct.unpack('<QQ', raw[:16])
    if isinstance(value, list) and len(value) >= 2:
        return value[0], value[1]
    raise ValueError(f'unsupported reg: {value!r}')


def fixup(root, nvram=b'', disable_network=False):
    root.props['platform-name'] = get_platform_name(root)
    gen = get_soc_gen(root)
    chosen = root['chosen']
    if gen <= 14:
        chosen.props['dram-base'] = {'u64': 0x800000000}
    else:
        chosen.props['dram-base'] = {'u64': 0x10000000000}
    chosen.props['dram-size'] = {'u64': 0x200000000}
    chosen.props['firmware-version'] = IBOOT_NAME
    chosen.props['system-firmware-version'] = IBOOT_NAME

    cpus = root['cpus']
    cpu0 = cpus['cpu0']
    cpu0.props['state'] = 'running'
    for key in ('memory-frequency', 'peripheral-frequency', 'fixed-frequency',
                'clock-frequency', 'timebase-frequency'):
        cpu0.props[key] = {'u32': FREQUENCY}

    seed = chosen.props.get('random-seed')
    if isinstance(seed, str):
        chosen.props['random-seed'] = 'A' * len(seed)
    elif isinstance(seed, dict) and 'bytes' in seed:
        chosen.props['random-seed'] = {'bytes': '41' * (len(seed['bytes']) // 2)}
    chosen.props['kernel-ctrr-to-be-enabled'] = {'u32': 0}

    defaults = root['defaults']
    uart0 = root['arm-io']['uart0']
    defaults.props['serial-device'] = uart0.props['AAPL,phandle']

    chosen.props['nvram-bank-count'] = {'u32': 1}
    chosen.props['nvram-current-bank'] = {'u32': 1}
    chosen.props['nvram-proxy-data'] = {'bytes': nvram.hex()}
    chosen.props['nvram-total-size'] = {'u32': len(nvram)}
    chosen.props['nvram-bank-size'] = {'u32': len(nvram)}

    try:
        nub = root['arm-io']['sep']['iop-sep-nub']
        if 'InvalidateHmac' in nub:
            hmac = nub['InvalidateHmac']
            hmac.props['config'] = {'u32': 1}
            hmac.props['sio-hmac1-offset'] = {'u64': 0}
            hmac.props['sio-hmac1-disable-mask'] = {'u64': 0xffffffffffffffff}
    except KeyError:
        pass

    root['arm-io'].remove_child('dockchannel-uart')
    if not disable_network:
        for i in range(1, NUM_TUNNEL_DEVICES + 1):
            root['arm-io'].add(copy_uart(uart0, i))

    root.props['no-rtc'] = ''
    rtc = Node('rtc')
    rtc.props['__placeholder_val'] = ''
    root.add(rtc)

    defaults.props['vmm-present'] = {'u32': 1}

    amcc = chosen['lock-regs']['amcc']
    amcc.props['aperture-count'] = {'u32': 1}
    amcc.props['aperture-size'] = {'u32': 0x4000}
    amcc.props['plane-count'] = {'u32': 1}
    amcc.props['plane-stride'] = {'u32': 0}
    amcc.props['plane-size'] = amcc.props['aperture-size']
    amcc.props['aperture-phys-addr'] = {'u64': 0x220000000}
    amcc.props['cache-status-reg-offset'] = {'u32': 0}
    amcc.props['cache-status-reg-mask'] = {'u32': 0}
    amcc.props['cache-status-reg-value'] = {'u32': 0}
    for i, letter in enumerate('abcd'):
        ctrr = amcc[f'amcc-ctrr-{letter}']
        ctrr.props['page-size-shift'] = {'u32': 0}
        ctrr.props['lower-limit-reg-offset'] = {'u32': AMCC_BANK_STRIDE * i + AMCC_LOWER_LIMIT_REG}
        ctrr.props['upper-limit-reg-offset'] = {'u32': AMCC_BANK_STRIDE * i + AMCC_UPPER_LIMIT_REG}
        ctrr.props['upper-limit-reg-mask'] = {'u32': 0xffffffff}
        ctrr.props['lower-limit-reg-mask'] = {'u32': 0xffffffff}
        ctrr.props['lock-reg-offset'] = {'u32': 0}
        ctrr.props['lock-reg-mask'] = {'u32': 0}
        ctrr.props['lock-reg-value'] = {'u32': 0}
        ctrr.props['enable-reg-offset'] = {'u32': 0}
        ctrr.props['enable-reg-mask'] = {'u32': 1}
        ctrr.props['enable-reg-value'] = {'u32': 1}
        ctrr.props['write-disable-reg-offset'] = {'u32': 0}
        ctrr.props['write-disable-reg-mask'] = {'u32': 1}
        ctrr.props['write-disable-reg-value'] = {'u32': 1}

    del_compat(root)
    fixup_aic(root['arm-io']['aic'])
    fixup_sptm(root)
    root.props.pop('secure-root-prefix', None)
    return root


def synthetic_tree():
    """Minimal fixture mirroring the fields touch_points() checks."""
    root = Node()
    root.props['secure-root-prefix'] = 'System/Library/CoreServices'
    root.add(Node('chosen'))
    arm_io = root.add(Node('arm-io'))
    arm_io.props['compatible'] = 'arm-io,t8101'
    arm_io.props['soc-generation'] = 'H13'
    aic = arm_io.add(Node('aic'))
    aic.props['compatible'] = 'aic,3'
    arm_io.add(Node('sgx'))
    uart0 = arm_io.add(Node('uart0'))
    uart0.props['compatible'] = 'uart-1,samsung'
    uart0.props['reg'] = {'bytes': struct.pack('<QQ', 0x35200000, 0x4000).hex()}
    uart0.props['interrupt-parent'] = {'u32': 37}
    uart0.props['AAPL,phandle'] = {'u32': 232}
    arm_io.add(Node('dockchannel-uart'))
    sep = arm_io.add(Node('sep'))
    nub = sep.add(Node('iop-sep-nub'))
    nub.add(Node('InvalidateHmac'))
    cpus = root.add(Node('cpus'))
    cpus.add(Node('cpu0'))
    defaults = root.add(Node('defaults'))
    chosen = root['chosen']
    chosen.props['random-seed'] = 'B' * 64
    chosen.add(Node('memory-map'))
    lock_regs = chosen.add(Node('lock-regs'))
    amcc = lock_regs.add(Node('amcc'))
    for letter in 'abcd':
        amcc.add(Node(f'amcc-ctrr-{letter}'))
    bogus = arm_io.add(Node('nonexistent-device'))
    bogus.props['compatible'] = 'fake,device'
    return root


def touch_points(root):
    """Assert the darwin-vm fixup contract; returns bitmask."""
    errors = E_OK
    chosen = root['chosen']
    if chosen.props.get('dram-base') != {'u64': 0x800000000}:
        errors |= E_FIXUP
    if chosen.props.get('firmware-version') != IBOOT_NAME:
        errors |= E_FIXUP
    if root['cpus']['cpu0'].props.get('state') != 'running':
        errors |= E_FIXUP
    if 'sgx' in root['arm-io']:
        errors |= E_FIXUP
    if 'dockchannel-uart' in root['arm-io']:
        errors |= E_FIXUP
    if [c.props.get('name') for c in root['arm-io'].children
        if str(c.props.get('name', '')).startswith(TUNNEL_DEVICE_PREFIX)] != \
            [f'qemuport{i}' for i in range(1, NUM_TUNNEL_DEVICES + 1)]:
        errors |= E_FIXUP
    if root['arm-io']['aic'].props.get('aic-iack-offset') != {'u64': 0x1000}:
        errors |= E_FIXUP
    if 'compatible' in [c for c in root['arm-io'].children
                        if c.props.get('name') == 'nonexistent-device'][0].props:
        errors |= E_FIXUP
    if root.props.get('no-rtc') != '' or 'rtc' not in [c.props.get('name') for c in root.children]:
        errors |= E_FIXUP
    if root['defaults'].props.get('vmm-present') != {'u32': 1}:
        errors |= E_FIXUP
    if 'secure-root-prefix' in root.props:
        errors |= E_FIXUP
    mmap = chosen['memory-map'].props
    for key in ('TXM-ro', 'BootKC-rx', 'TrustCache', 'RAMDisk'):
        if mmap.get(key, {}).get('bytes') != 'ff' * 16:
            errors |= E_FIXUP
    if mmap.get('slide', {}).get('bytes') != '00' * 16:
        errors |= E_FIXUP
    return errors


def selftest():
    errors = E_OK
    root = synthetic_tree()
    try:
        data = encode(root)
        back = decode(data)
        if data != encode(back):
            errors |= E_ROUNDTRIP
    except Exception as exc:
        print(f'roundtrip failed: {exc}', file=sys.stderr)
        errors |= E_DECODE | E_ENCODE
    try:
        fixed = fixup(synthetic_tree(), nvram=b'CHRP-NVRAM', disable_network=False)
        errors |= touch_points(fixed)
        encoded = encode(fixed)
        decode(encoded)
    except Exception as exc:
        print(f'fixup failed: {exc}', file=sys.stderr)
        errors |= E_FIXUP | E_SCHEMA
    return errors


def main(argv=None):
    p = argparse.ArgumentParser(description='Apple Device Tree codec + fixup')
    sub = p.add_subparsers(dest='cmd', required=True)

    pd = sub.add_parser('decode')
    pd.add_argument('input')
    pd.add_argument('-o', '--output')

    pe = sub.add_parser('encode')
    pe.add_argument('input')
    pe.add_argument('-o', '--output', required=True)

    pf = sub.add_parser('fixup')
    pf.add_argument('input')
    pf.add_argument('output')
    pf.add_argument('-nvram', required=True)
    pf.add_argument('--no-network', action='store_true')

    sub.add_parser('selftest')

    args = p.parse_args(argv)
    if args.cmd == 'selftest':
        rc = selftest()
        print(f'selftest rc=0x{rc:x}')
        return rc
    if args.cmd == 'decode':
        try:
            root = decode(open(args.input, 'rb').read())
        except Exception as exc:
            print(f'decode failed: {exc}', file=sys.stderr)
            return E_DECODE
        text = json.dumps(to_json_obj(root), ensure_ascii=False, indent=2)
        if args.output:
            open(args.output, 'w', encoding='utf-8').write(text)
        else:
            print(text)
        return E_OK
    if args.cmd == 'encode':
        try:
            root = from_json_obj(json.load(open(args.input, encoding='utf-8')))
            data = encode(root)
            open(args.output, 'wb').write(data)
        except Exception as exc:
            print(f'encode failed: {exc}', file=sys.stderr)
            return E_ENCODE
        return E_OK
    if args.cmd == 'fixup':
        try:
            root = decode(open(args.input, 'rb').read())
            nvram = open(args.nvram, 'rb').read()
            fixed = fixup(root, nvram=nvram, disable_network=args.no_network)
            open(args.output, 'wb').write(encode(fixed))
        except Exception as exc:
            print(f'fixup failed: {exc}', file=sys.stderr)
            return E_FIXUP
        return E_OK
    return E_SCHEMA


if __name__ == '__main__':
    sys.exit(main())
