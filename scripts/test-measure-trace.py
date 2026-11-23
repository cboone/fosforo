"""Compare executed Python measurement helpers with their Zig counterparts.

Run with: uv run --with pillow --with numpy python scripts/test-measure-trace.py
The Zig version pinned in build.zig.zon must be on PATH. No GPU, host or capture is needed.
"""

import contextlib
import io
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
TOOL = runpy.run_path(str(ROOT / "scripts/measure-trace"))


def row_cases():
    for height in (1, 2, 3, 15, 16, 269, 270, 539, 540, 541, 1080, 1081, 2160):
        for peak in sorted({0, height // 4, height // 2, height - 1}):
            yield height, peak


def image_cases():
    for height in range(1, 17):
        yield height, [-1] * 8
        for peak in range(height):
            band = TOOL["period_band"](height, peak)
            # Include each neighbour of the band, dark gaps and joined runs.
            rows = sorted({peak, max(peak, int(band)), min(height - 1, int(band) + 1)})
            for row in rows:
                yield height, [peak, -1, row, -1, row, row, height - 1, -1]


def prepare_fixture(directory):
    rows = []
    for height, peak in row_cases():
        centre = TOOL["centre_row"](height)
        rail, bottom = TOOL["rail_rows"](height)
        band = TOOL["period_band"](height, peak)
        rows.append(
            f".{{ .height = {height}, .peak = {peak}, .centre = {centre}, "
            f".rail = {rail}, .bottom = {bottom}, .band = {band} }}"
        )
    images = []
    for height, top in image_cases():
        array = np.array(top)
        count = TOOL["periods"](array, array >= 0, height)
        values = ", ".join(map(str, top))
        images.append(f".{{ .height = {height}, .top = &.{{ {values} }}, .periods = {count} }}")
    source = (
        "pub const Row = struct {height: usize, peak: usize, centre: f32, rail: f32, bottom: f32, band: f32};\n"
        "pub const rows = [_]Row{\n" + ",\n".join(rows) + "\n};\n"
        "pub const Image = struct {height: usize, top: []const i32, periods: usize};\n"
        "pub const images = [_]Image{\n" + ",\n".join(images) + "\n};\n"
    )
    cases = directory / "cases.zig"
    cases.write_text(source)
    result = subprocess.run(
        [
            "zig",
            "build",
            "build-measure",
            f"-Dmeasurement-cases={cases}",
            "--prefix",
            str(directory),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return directory / "bin/measurement-parity"


class MeasurementParity(unittest.TestCase):
    def test_derived_helpers_agree(self):
        with tempfile.TemporaryDirectory(prefix="fosforo-parity-") as directory:
            binary = os.environ.get("MEASURE_PARITY_BINARY") or prepare_fixture(Path(directory))
            result = subprocess.run([str(binary)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cli_uses_helpers(self):
        main = TOOL["main"]
        # A generated drawable exercises the printed geometry and --periods path.
        pixels = np.full((541, 8, 3), 5, dtype=np.uint8)
        pixels[:, :, 2] = 8
        top = np.array([0, -1, 135, -1, 135, 135, 540, -1])
        for x, row in enumerate(top):
            if row >= 0:
                pixels[row, x] = [32, 200, 32]
        image = Image.fromarray(pixels)
        output = io.StringIO()
        counter = Mock(wraps=TOOL["periods"])
        with (
            patch.dict(main.__globals__, {"open_image": lambda _: image, "periods": counter}),
            patch.object(
                sys,
                "argv",
                [
                    "measure-trace",
                    "generated.png",
                    "--no-crop",
                    "--measure-anyway",
                    "--threshold",
                    "16",
                    "--periods",
                ],
            ),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(main(), 0)
        counter.assert_called_once()
        self.assertIn(f"centre row       {TOOL['centre_row'](image.height):.1f}", output.getvalue())
        rail, bottom = TOOL["rail_rows"](image.height)
        self.assertIn(f"rail rows        {rail:.1f} / {bottom:.1f}", output.getvalue())
        self.assertIn(
            f"periods          {TOOL['periods'](top, top >= 0, image.height)}", output.getvalue()
        )


if __name__ == "__main__":
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    if len(sys.argv) == 3 and sys.argv[1] == "--prepare":
        directory = Path(sys.argv[2]).resolve()
        directory.mkdir(parents=True, exist_ok=True)
        print(prepare_fixture(directory))
    else:
        unittest.main()
