#!/usr/bin/env python3
"""Read-only canonical initial-entry site witness inspection.
Envelope verifier: unchanged inspect_retry_tape.records(), profile9/wire2.
Payload schema: live_semantic_codec.{Cut,PacketInput,putPacketInput,
encodePointReferences,Encoder.put}; live_semantic_hooks.Point.
This is NOT full Zig semantic preflight, build admission, or native replay.
"""
import argparse
import hashlib
import json
import pathlib
import struct
from inspect_retry_tape import Decoder, records, require

TARGETS = {0x7A: 'service_initial_entry_consumed', 0x7B: 'service_initial_entry_cancel'}
# capture_order.Site enum at this source checkpoint. Unknown sites fail closed.
KNOWN_SITES = set(range(0, 4)) | set(range(0x20, 0x4A)) | set(range(0x4D, 0x71)) | set(range(0x72, 0x7C)) | set(range(0x80, 0x93)) | {0xA0, 0xB0, 0xB1, 0xB2, 0xB3, 0xC0}
MAX_TARGET_POINTS = 65536
NATIVE_TO_WIRE = {0: 0, 1: 2, 2: 1}

class PointDecoder(Decoder):
    def varint(self):
        value = 0
        for i in range(10):
            byte = self.get('u8')
            low = byte & 127
            require(i != 9 or (byte & 128 == 0 and low <= 1), 'varint overflow')
            value |= low << (7 * i)
            if byte & 128 == 0:
                require(i == 0 or low != 0, 'overlong varint')
                return value
        raise ValueError('unterminated varint')

def coordinate(occurrence, role, site, edge, index, generation, prefix):
    require(occurrence > 0 and role in (0, 1, 2), 'unsupported point occurrence/role')
    require(site in KNOWN_SITES and edge in (0, 1), 'unsupported point site/edge')
    if site in TARGETS:
        require(role == 0 and index < 64 and generation > 0, 'initial-entry role/identity')
        require(prefix == 0 if edge == 0 or site == 0x7B else True, 'unsupported initial-entry input prefix')
    return dict(occurrence=occurrence, role=role, site=site, edge=edge,
                index=index, generation=generation, publication_prefix=prefix)

def decode_points(payload, role, family):
    """Yield copied canonical fields and payload-relative offsets; no ABI casts."""
    require(family in (1, 11, 101, 115), 'unsupported point family')
    d = PointDecoder(payload)
    packet = family in (11, 115)
    reference = family in (101, 115)
    count = d.get('u16') if packet else 1
    require(0 < count <= 512, 'packet count')
    last = 0
    result = []
    for _ in range(count):
        offset = d.p
        occurrence = d.varint() if packet else d.get('u64')
        require(occurrence > last, 'packet occurrence order')
        last = occurrence
        if packet:
            site, edge = d.get('u16'), d.get('u8')
            index, generation, prefix = d.varint(), d.varint(), d.varint()
        else:
            embedded_role = d.get('u64')
            if reference:
                require(embedded_role in NATIVE_TO_WIRE, 'native Point role')
                embedded_role = NATIVE_TO_WIRE[embedded_role]
            require(embedded_role == role, 'record/payload role mismatch')
            site, edge, index, generation = [d.get('u64') for _ in range(4)]
            prefix = None if reference else d.get('u64')
        # Raw Point contains no scheduling prefix. Match it independently to Cut.
        row = coordinate(occurrence, role, site, edge, index, generation,
                         0 if prefix is None else prefix)
        row['publication_prefix'] = prefix
        row['payload_relative_offset'] = offset
        if reference:
            present = d.get('bool')
            bits = d.varint() if packet else (d.get('u64') if present else 0)
            require(present or bits == 0, 'noncanonical absent point value')
            row['value'] = bits if present else None
        result.append(row)
    d.finish()
    return result

def inspect(data):
    identities, entries = records(data)
    lanes = {'input': {}, 'reference': {}}
    last = {}
    markers = {}
    public_counts = {'public_input_108': 0, 'schedule_109': 0}
    point_counts = {'input': 0, 'reference': 0}
    for off, role, cls, family, ordinal, payload in entries:
        if family in (108, 109):
            public_counts['public_input_108' if family == 108 else 'schedule_109'] += 1
        if family == 9:
            d = Decoder(payload)
            occ, referenced, tag = d.get('u64'), d.get('u64'), d.get('u16')
            d.finish()
            if referenced == 101:
                require((role, occ) not in markers and tag == 0, 'duplicate/unsupported raw Point marker')
                markers[role, occ] = off
        if family not in (1, 11, 101, 115):
            continue
        lane = 'input' if family in (1, 11) else 'reference'
        for row in decode_points(payload, role, family):
            key = (role, row['occurrence'])
            previous = last.get((lane, role), 0)
            require(row['occurrence'] > previous, 'point lane occurrence order')
            last[lane, role] = row['occurrence']
            point_counts[lane] += 1
            if row['site'] not in TARGETS:
                continue
            require(len(lanes[lane]) < MAX_TARGET_POINTS, 'initial-entry witness bound')
            row.update(record_offset=off, role_ordinal=ordinal, family=family,
                       file_offset=off + 64 + row['payload_relative_offset'])
            lanes[lane][key] = row
    require(lanes['input'].keys() == lanes['reference'].keys(), 'initial-entry Input/Reference occurrence set mismatch')
    pairs = []
    pending = None
    for key in sorted(lanes['input'], key=lambda k: k[1]):
        source, reference = lanes['input'][key], lanes['reference'][key]
        for name in ('occurrence', 'role', 'site', 'edge', 'index', 'generation'):
            require(source[name] == reference[name], 'initial-entry Input/Reference coordinate mismatch: ' + name)
        if reference['publication_prefix'] is not None:
            require(source['publication_prefix'] == reference['publication_prefix'], 'packet Input/Reference prefix mismatch')
        if source['family'] == 1:
            require(key in markers, 'missing raw cut_fact marker')
        if source['edge'] == 0:
            require(reference['value'] is None and pending is None, 'initial-entry BEFORE value/nesting')
            pending = (source, reference)
        else:
            require(pending is not None, 'initial-entry AFTER without BEFORE')
            before, before_ref = pending
            require(all(before[n] == source[n] for n in ('role', 'site', 'index', 'generation')), 'crossed initial-entry bracket identity')
            require(before['occurrence'] < source['occurrence'], 'initial-entry bracket order')
            if source['site'] == 0x7A:
                require(reference['value'] == source['publication_prefix'] == 0, 'raw consumed is not actual zero')
            else:
                require(reference['value'] in (0, 1), 'cancel value is not boolean')
            pairs.append(dict(site=TARGETS[source['site']], before=before, after=source,
                              before_reference=before_ref, after_reference=reference))
            pending = None
    require(pending is None, 'incomplete initial-entry bracket')
    return dict(file_sha256=hashlib.sha256(data).hexdigest(), file_bytes=len(data),
                identities=identities, envelope_hashes_counts_eof_verified=True,
                point_counts=point_counts, canonical_record_counts=public_counts,
                paired_counts={name: sum(p['site'] == name for p in pairs) for name in TARGETS.values()},
                pairs=pairs, limitations=[
                    'Only listed point payloads are decoded; 108/109 are counted, not semantically decoded.',
                    'Target coordinates, brackets and actual reference values are checked independently.',
                    'No full Zig preflight, expected build identity admission, PCM admission, or native replay is established.',
                    'Zero target pairs means absent coverage, not successful qualification.'])

def self_test():
    # Synthetic parser tests only. Does not construct or qualify a native tape.
    def vu(n):
        out = bytearray()
        while True:
            b = n & 127; n >>= 7
            out.append(b | (128 if n else 0))
            if not n: return bytes(out)
    body = vu(1) + struct.pack('<HB', 0x7A, 0) + vu(3) + vu(7) + vu(0)
    raw = struct.pack('<7Q', 1, 0, 0x7A, 0, 3, 7, 0)
    assert decode_points(struct.pack('<H', 1) + body, 0, 11)[0]['generation'] == 7
    assert decode_points(struct.pack('<H', 1) + body + b'\0\0', 0, 115)[0]['value'] is None
    assert decode_points(raw, 0, 1)[0]['site'] == 0x7A
    assert decode_points(raw[:-8] + b'\0', 0, 101)[0]['value'] is None
    malformed = [b'\0\0', b'\1\0\x81\0' + body[1:], struct.pack('<H', 1) + body + b'\0',
                 struct.pack('<H', 1) + body[:-1] + b'\1', struct.pack('<H', 1) + body[:-1]]
    for payload in malformed:
        try: decode_points(payload, 0, 11)
        except ValueError: pass
        else: raise AssertionError('malformed packet accepted')
    try: decode_points(struct.pack('<H', 1) + body, 1, 11)
    except ValueError: pass
    else: raise AssertionError('wrong role accepted')
    return {'synthetic_parser_cases': 10, 'native_or_full_envelope_qualification': False}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tape', type=pathlib.Path, nargs='?')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    require(args.self_test != (args.tape is not None), 'choose tape OR --self-test')
    if args.self_test:
        result = self_test()
    else:
        require(args.tape.stat().st_size <= 512 * 1024 * 1024, 'file bound')
        result = inspect(args.tape.read_bytes())
    print(json.dumps(result, indent=2))
