"""Fetches the homebrew MD test ROMs that the Exodus emulator documentation links to (Google Drive) into .build/.

https://techdocs.exodusemulator.com/Console/SegaMegaDrive/Software.html
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, extract_zip, run  # noqa: E402

# file in .build/ -> (Drive file id, sha256 of the zip, member)
ROMS = {
    "bcd-verifier.bin": ("1EgwX-T4g9bUcsGc6FywO_-4Irxjo1Vgn", "a72f581cc39932d65cec8de3db04cbbda8dc5daf2a631115ba44c6302f5a01f4", "bcd-verifier-u1.bin"),
    "opcode-sizes.bin": ("1VGTj6ZTLS7eVzqXuiCXmkdBBVnZ6KfJQ", "04115b3488d8147d6f3ef3bd7ab04b251767cb89417423815c4471bd6d50200a", "m68k_opcode_sizes.bin"),
    "illegal-opcodes.bin": ("1NKagoNVmUEZB9DojKcmXSsSlJY96xS8-", "df3b0703edae0ed199d32a82bcdb016eac0b4e6f0fdcf4906a6c4b4f29274645", "itest.BIN"),
    "vcounter.bin": ("1OULXRZwJd11D4Y5vVtEX11EugzuUELqf", "6fb02e57667396fa5ab6274f385307ca7023fc04e1307f24aae19b674d65272a", "vctest.bin"),
    "cram-flicker.bin": ("1-FZqLceTxBnzJv8AR4bBTAUZqS_pyjT-", "bd59f1b6be7a8e929f6ad13a5bb10a880fe8274a81f34cd212c35767da431834", "cram flicker.bin"),
    "vdp-fifo.bin": ("19vQuo8diG5OQMD5ythejtJByFzOwIl4i", "c6aee1cdaeab87beb7c7e5b4cb15fe5db52501bdaa665f1fce8b07101c1bcd24", "VDPFIFOTesting.bin"),
    "sprite-masking.bin": ("14qAO4_EKKN2bcumExkv-RgTcl9H_Auzq", "0db3f503bc6adc9f9565442f7d72b969cabd3dcc4b378c8da0e7dcba5fcb688b", "SpriteMaskingTestRom.bin"),
    "vdp-disable-reg.bin": ("1W08doQKWZPEx7xJX4KlVgBsNMS--zzU3", "9b821b295850541f5d74f954c704aef4c31209866b95f9c031f3f7875f9dae7b", "DisableRegTestROM.bin"),
    "memtest-68k.bin": ("1btAFafip50yCpAV74R6hh0QOjN0XBv-L", "642758c92d74d5f046eafb628d3637adde5a1dd261747ca08a248fd28b96da8a", "memtest_68k.bin"),
    "color-1536.bin": ("1h5JZkMaq_43X4XTq5uYfBWIJg-cKtMrV", "a3f87e98fdd230d308166f591675a98973a9b1118470f09dc32c06e357338761", "TEST1536.BIN"),
    "shadow-highlight.bin": ("1bmO4bE1NeDfIC1jxrC4GZc17xggthT3J", "d0cdc2eac5acf1ce165a7f1d8785dfdee3f6b409ea6b667a25af56db342499d1", "Shadow-Highlight Test Program #2 (PD).bin"),
    "window.bin": ("169ZUeEMrfYFLiKz1jpb53zJQJg1Wba00", "b50b5ed12f8d3a6463819e852d9b60e2a5da3078c07b7c10c2194bd25293aed9", "Window Test by Fonzie (PD).bin"),
    "window-distortion.bin": ("1nDITsbkmo3BYRve6NX35Aqt7jo7FWtqP", "466f75d15fdaf8e9e0f347fd343eda83f587072e191540ad5554b5031eb810a5", "Window distortion bug.BIN"),
}


def setup():
    out = build_dir(__file__)
    for name, (file_id, digest, member) in ROMS.items():
        if (out / name).exists():
            continue
        archive = download(f"https://drive.google.com/uc?export=download&id={file_id}", out / f"{name}.zip", digest)
        extract_zip(archive, {member: out / name})
        archive.unlink()


run(setup)
