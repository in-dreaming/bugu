#!/usr/bin/env python3
"""Render the original Lantern Circuit score with Python's standard library.

All PCM arithmetic is integer-only, with explicit little-endian output. No
runtime, compiler, sample library, external synthesizer or random module is used.
This is source-asset authoring, never a substitute for Bugu runtime rendering.
"""

import argparse
import array
import hashlib
import json
from pathlib import Path
import struct
import sys

HERE = Path(__file__).resolve().parent
EXAMPLE = HERE.parent
RATE = 48_000
Q = 32_767
PHASE = 1 << 32
TABLE_SIZE = 4096
ROLES = ("harmony", "bass", "motif", "percussion")
STATES = ("explore", "tension", "combat", "dialogue")
BASE_MILLIHZ = (261626, 277183, 293665, 311127, 329628, 349228,
               369994, 391995, 415305, 440000, 466164, 493883)
SOURCE_BUDGET = 13 * 1024 * 1024
SINGLE_BUDGET = 768_044
PACKAGE_BUDGET = 14 * 1024 * 1024
COMMAND = "python3 examples/sme/assets/generate.py --output-dir examples/sme/audio"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def rounded_wave(index):
    """A symmetric rational oscillator table, evaluated without libm."""
    half = TABLE_SIZE // 2
    x = index % half
    product = x * (half - x)
    value = 16 * product * Q // (5 * half * half - 4 * product)
    return value if index < half else -value


WAVE = tuple(rounded_wave(i) for i in range(TABLE_SIZE))


def frequency_step(midi):
    octave, pitch = divmod(midi - 60, 12)
    numerator = BASE_MILLIHZ[pitch] * PHASE
    denominator = RATE * 1000
    if octave >= 0:
        numerator <<= octave
    else:
        denominator <<= -octave
    return (numerator + denominator // 2) // denominator


def oscillator(phase):
    return WAVE[(phase & (PHASE - 1)) >> 20]


def note(midi, frames, velocity, instrument):
    step = frequency_step(midi)
    attack = min(frames // 4, {"pad": 4800, "bass": 192,
                              "bell": 96, "lead": 480}[instrument])
    release = min(frames // 3, 2400 if instrument == "pad" else 960)
    result = []
    phase = 0
    for i in range(frames):
        envelope = min(Q, i * Q // max(1, attack),
                       (frames - 1 - i) * Q // max(1, release))
        if instrument in ("bell", "bass"):
            # A squared linear decay gives a plucked envelope without exp().
            remaining = (frames - i) * Q // frames
            envelope = envelope * (Q // 5 + remaining * remaining * 4 // (5 * Q)) // Q
        fundamental = oscillator(phase)
        if instrument == "pad":
            sample = (fundamental * 8 + oscillator(phase * 2)
                      + oscillator(phase * 3)) // 10
        elif instrument == "bass":
            sample = (fundamental * 4 + oscillator(phase * 2)) // 5
        elif instrument == "bell":
            sample = (fundamental * 5 + oscillator(phase * 2) * 2
                      + oscillator(phase * 3)) // 8
        else:
            sample = (fundamental * 4 + oscillator(phase * 2) * 2
                      + oscillator(phase * 3)) // 7
        result.append(sample * envelope * velocity // (Q * Q))
        phase += step
    return result


def drum(kind, velocity, seed):
    frames = {"kick": 9600, "snare": 7200, "hat": 1800, "tom": 8400}[kind]
    result, phase, previous, low = [], 0, 0, 0
    for i in range(frames):
        seed ^= (seed << 13) & 0xffffffff
        seed ^= seed >> 17
        seed ^= (seed << 5) & 0xffffffff
        seed &= 0xffffffff
        noise = (seed & 0xffff) - 32768
        high = (noise - previous) // 2
        previous = noise
        low += (noise - low) // 6
        decay = (frames - 1 - i) * Q // frames
        envelope = decay * decay // Q
        envelope = envelope * min(Q, i * Q // 32) // Q
        if kind in ("kick", "tom"):
            base, sweep = (48, 90) if kind == "kick" else (108, 72)
            hz = base + sweep * decay * decay // (Q * Q)
            phase += hz * PHASE // RATE
            sample = oscillator(phase)
        elif kind == "snare":
            phase += 185 * PHASE // RATE
            sample = (high * 4 + low * 2 + oscillator(phase)) // 7
        else:
            sample = high // 2
        result.append(sample * envelope * velocity // (Q * Q))
    return result


def add(buffer, sound, start):
    if start < 0 or start >= len(buffer):
        raise ValueError("note starts outside asset")
    for i in range(min(len(sound), len(buffer) - start)):
        buffer[start + i] += sound[i]


def wav_bytes(samples):
    # A two-millisecond microfade makes both value and first difference zero at
    # the package loop join. It does not time-stretch or shift the shared grid.
    for i in range(96):
        scale = i * i
        samples[i] = samples[i] * scale // (96 * 96)
        samples[-1 - i] = samples[-1 - i] * scale // (96 * 96)
    if min(samples) < -32768 or max(samples) > 32767:
        raise ValueError("source would clip; lower authored velocities")
    pcm = array.array("h", samples)
    if pcm.itemsize != 2:
        raise RuntimeError("16-bit array representation required")
    if sys.byteorder != "little":
        pcm.byteswap()
    payload = pcm.tobytes()
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(payload),
                         b"WAVE", b"fmt ", 16, 1, 1, RATE, RATE * 2, 2, 16,
                         b"data", len(payload))
    return header + payload


def render(score):
    if (score["sample_rate_hz"], score["bpm"], score["beats_per_bar"],
            score["subdivisions_per_beat"], score["bars_per_loop"], score["ppq"]) != (
            RATE, 120, 4, 4, 4, 960):
        raise ValueError("this source edition has a frozen 120 BPM, four-bar grid")
    if tuple(state["id"] for state in score["states"]) != STATES:
        raise ValueError("unexpected state inventory")
    step_frames, bar_frames, loop_frames = 6000, 96000, 384000
    for state in score["states"]:
        state_id = state["id"]
        for role in ROLES:
            buffer = [0] * loop_frames
            for bar in range(4):
                origin = bar * bar_frames
                if role == "harmony":
                    strikes = (0, 6, 10) if state_id == "combat" else (0,)
                    length = 4 * step_frames if state_id == "combat" else bar_frames
                    for strike in strikes:
                        for midi in state["chords"][bar]:
                            add(buffer, note(midi, length, state["harmony_velocity"],
                                             "lead" if state_id == "combat" else "pad"),
                                origin + strike * step_frames)
                elif role == "bass":
                    for start, duration, offset, velocity in state["bass_pattern"]:
                        add(buffer, note(state["roots"][bar] + offset,
                                         duration * step_frames, velocity, "bass"),
                            origin + start * step_frames)
                elif role == "motif":
                    for start, midi, duration, velocity in state["motifs"][bar]:
                        add(buffer, note(midi, duration * step_frames, velocity,
                                         "lead" if state_id == "combat" else "bell"),
                            origin + start * step_frames)
                else:
                    for kind in ("kick", "snare", "hat"):
                        for start in state[kind]:
                            seed = int(sha(f"{state_id}:{bar}:{kind}:{start}".encode())[:8], 16) or 1
                            accent = state["drum_velocity"] * (3 if start % 4 == 0 else 2) // 3
                            add(buffer, drum(kind, accent, seed), origin + start * step_frames)
            yield {
                "id": f"{state_id}-{role}", "role": role, "state": state_id,
                "frames": loop_frames, "loop": True,
                "score_ref": f"states.{state_id}.{role}", "project_inclusion": True,
            }, wav_bytes(buffer)
    for item in score["one_shots"]:
        buffer = [0] * (item["steps"] * step_frames)
        for start, midi, duration, velocity in item["notes"]:
            add(buffer, note(midi, duration * step_frames, velocity, "bell"), start * step_frames)
        for kind, start, velocity in item["drums"]:
            seed = int(sha(f"{item['id']}:{kind}:{start}".encode())[:8], 16) or 1
            add(buffer, drum(kind, velocity, seed), start * step_frames)
        yield {
            "id": item["id"], "role": item["kind"], "state": "reserved",
            "frames": len(buffer), "loop": False,
            "score_ref": f"one_shots.{item['id']}", "project_inclusion": False,
        }, wav_bytes(buffer)


def manifest_text(records):
    lines = [
        '# Original generated PCM source inventory; paths are repository-relative.',
        'format = "bugu.sme.asset-foundation/v1"',
        'scope = "source-assets-only; no compiled-bank or runtime qualification"',
        f'generator = "examples/sme/assets/generate.py"',
        f'generator_sha256 = "{sha(Path(__file__).read_bytes())}"',
        f'score_sha256 = "{sha((HERE / "score.json").read_bytes())}"',
        f'generation_command = "{COMMAND}"',
        'license = "MIT"', 'license_file = "LICENSE"',
        f'source_audio_budget_bytes = {SOURCE_BUDGET}',
        f'single_asset_budget_bytes = {SINGLE_BUDGET}',
        f'foundation_package_budget_bytes = {PACKAGE_BUDGET}',
        f'source_audio_total_bytes = {sum(r["bytes"] for r in records)}',
        f'asset_count = {len(records)}',
    ]
    for record in records:
        lines.extend([
            '', '[[assets]]', f'logical_id = "{record["id"]}"',
            f'path = "examples/sme/audio/{record["id"]}.wav"',
            f'source = "examples/sme/assets/score.json#{record["score_ref"]}"',
            f'generation_command = "{COMMAND}"',
            'license = "MIT"', 'copyright = "Copyright (c) 2026 in dreaming"',
            f'sha256 = "{record["sha256"]}"', f'bytes = {record["bytes"]}',
            'sample_rate_hz = 48000', 'channels = 1', 'bits_per_sample = 16',
            f'frames = {record["frames"]}', f'role = "{record["role"]}"',
            f'state = "{record["state"]}"', f'loop = {str(record["loop"]).lower()}',
            'include_in_source_package = true', 'include_as_raw_runtime_file = false',
            f'include_in_foundation_project = {str(record["project_inclusion"]).lower()}',
        ])
    return "\n".join(lines) + "\n"


def project_text(records):
    # These are existing source/v1 fields from schema.zig and music_schema.zig.
    # Derived grids, bank rows, media reports and runtime receipts are not authored.
    profile = sha(b"Lantern Circuit foundation: 48000 Hz mono; resident segment cap 8388608 bytes; v1")
    lines = [
        '# Authored source foundation only. Runtime/demo qualification outstanding.',
        '# Regenerate with assets/generate.py --write-metadata after intentional edits.',
        'schema="bugu.music.source/v1"', 'generation=20', 'initial_state="explore"',
        'profile="lantern-source-v1"',
        'required_capabilities=["core","tempo","selection","transitions","bus"]',
        '[[platforms]]', 'id="lantern-source-v1"', f'profile_hash="{profile}"',
        'resident_limit_bytes=8388608',
        '[[themes]]', 'id="lantern"', 'initial_segment="explore-loop"',
        '[[buses]]', 'id="music"', 'layout="mono"', 'channel_mask=4',
        '[[tempos]]', 'id="four-bars-120"', 'ppq=960', 'spans={first=0,count=1}',
        'loop_present=true', 'loop_start_tick=0', 'loop_end_tick=15360',
        '[[tempo_spans]]', 'id="steady-120"', 'end_tick=15360',
        'start_milli_bpm=120000', 'end_milli_bpm=120000', 'numerator=4', 'denominator=4',
    ]
    for record in records:
        if not record["project_inclusion"]:
            continue
        lines.extend([
            '', '[[sounds]]', f'id="{record["id"]}"', f'source="audio/{record["id"]}.wav"',
            'layout="mono"', 'channels=1', 'channel_mask=4',
            f'source_import={{version=1,source_hash="{record["sha256"]}",source_rate_hz=48000,source_layout="mono",source_channel_mask=4,loop={{start=0,end=384000}}}}',
        ])
    for i, state in enumerate(STATES):
        lines.extend([
            '', '[[states]]', f'id="{state}"', 'theme="lantern"', f'selector="{state}-fixed"',
            '[[selectors]]', f'id="{state}-fixed"', 'kind="fixed"', f'candidates={{first={i},count=1}}',
            '[[candidates]]', f'id="{state}-choice"', f'segment="{state}-loop"',
            '[[segments]]', f'id="{state}-loop"', 'theme="lantern"', 'tempo="four-bars-120"',
            'storage="resident"', f'layers={{first={i * 4},count=4}}', f'cues={{first={i * 2},count=2}}',
            'loop_start=0', 'loop_end=384000',
        ])
        for role in ROLES:
            lines.extend([
                '[[layers]]', f'id="{state}-{role}-layer"', f'segment="{state}-loop"',
                f'sound="{state}-{role}"', 'bus="music"', 'gain_db=0', 'required=true',
            ])
        for kind, tick in (("entry", 0), ("exit", 15360)):
            lines.extend([
                '[[cues]]', f'id="{state}-{kind}"', f'segment="{state}-loop"',
                f'kind="{kind}"', f'tick={tick}',
            ])
    for i, state in enumerate(STATES):
        target = STATES[(i + 1) % len(STATES)]
        edge = f"{state}-to-{target}"
        lines.extend([
            '', '[[transitions]]', f'id="{edge}"', f'from="{state}"', f'to="{target}"',
            f'selector="{target}-fixed"', f'source_exit="{state}-exit"',
            f'target_entry="{target}-entry"', f'fill="{edge}-zero-steps"',
            'sync="authored_exit_cue"', 'fallback="next_boundary"',
            f'paths={{first={i},count=1}}',
            '[[transition_paths]]', f'id="{edge}-direct"', f'transition="{edge}"',
            f'source_exit="{state}-exit"', f'target_entry="{target}-entry"',
            f'fill="{edge}-zero-steps"', 'handoff="hard_cut"',
            # The existing transitions capability requires a nonempty fills
            # table. A zero-step route truthfully models this direct handoff.
            '[[fills]]', f'id="{edge}-zero-steps"',
            f'source_exit="{state}-exit"', f'target_entry="{target}-entry"',
            'steps={first=0,count=0}',
        ])
    return "\n".join(lines) + "\n"


def generate(output_dir, write_metadata=False):
    score = json.loads((HERE / "score.json").read_text())
    output_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for record, data in render(score):
        if len(data) > SINGLE_BUDGET:
            raise ValueError("single source budget exceeded")
        (output_dir / (record["id"] + ".wav")).write_bytes(data)
        records.append(dict(record, bytes=len(data), sha256=sha(data)))
    if sum(record["bytes"] for record in records) > SOURCE_BUDGET:
        raise ValueError("source audio budget exceeded")
    if write_metadata:
        (EXAMPLE / "LICENSES" / "assets.toml").write_text(manifest_text(records))
        (EXAMPLE / "project.toml").write_text(project_text(records))
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=EXAMPLE / "audio")
    parser.add_argument("--write-metadata", action="store_true",
                        help="refresh committed manifest and source project after intentional score edits")
    args = parser.parse_args()
    records = generate(args.output_dir, args.write_metadata)
    print(json.dumps({"scope": "generated-source-pcm-only", "assets": records,
                      "source_audio_total_bytes": sum(r["bytes"] for r in records)}, indent=2))


if __name__ == "__main__":
    main()
