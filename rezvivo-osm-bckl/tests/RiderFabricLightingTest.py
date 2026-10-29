"""Check the cloth sky lobe against independent BRDF hemisphere quadrature.

The sun uses Charlie distribution / Neubelt visibility. Its integrated response
must also be used for diffuse sky lighting, instead of substituting a GGX DFG.
No game, GPU, LUT asset, or fitting step is needed to build the application.
Reference model: https://google.github.io/filament/main/filament.html#materialsystem/clothmodel
"""
from pathlib import Path
import re

import numpy as np
from numpy.polynomial.legendre import leggauss
from numpy.polynomial.polynomial import polyval2d


def coefficients():
    source = (Path(__file__).resolve().parents[2] /
              'Bikeparametric/RiderFabricShader.pas').read_text(encoding='utf-8-sig')
    # Read actual shader coefficients; independently integrate the BRDF below.
    number = r'([+-]?\d+\.\d+)'
    pattern = r'float c\d=\(\(' + number + r'\*y' + number + r'\)\*y' + number + r'\)\*y' + number
    rows = re.findall(pattern, source)
    assert len(rows) == 5, rows
    return np.array([[float(x) for x in row[::-1]] for row in rows])


def main():
    co = coefficients()
    # Gauss-Legendre integration of light elevation, uniform azimuth. No
    # reflection-vector/DFG approximation is used in this reference integral.
    q, weights = leggauss(160)
    nl = ((q + 1) / 2)[:, None]
    weights /= 2
    phi = (np.arange(320) + .5) * (2 * np.pi / 320)
    lx = np.sqrt(1 - nl * nl) * np.cos(phi)
    worst = 0.0
    cases = 0
    for roughness in np.linspace(.5, 1, 25):
        for nv in np.r_[0, np.geomspace(1e-6, .1, 20), np.linspace(.1, 1, 31)]:
            nh = (nl + nv) / np.sqrt(np.maximum(
                2 + 2 * (lx * np.sqrt(1 - nv * nv) + nl * nv), 1e-20))
            inv_alpha = 1 / roughness**2
            distribution = ((2 + inv_alpha) * np.maximum(1 - nh * nh, 0)**
                            (.5 * inv_alpha) / (2 * np.pi))
            visibility = 1 / (4 * (nl + nv - nl * nv))
            reference = (distribution * visibility * nl).mean(axis=1) @ weights * (2 * np.pi)
            approximate = polyval2d(nv**.25, 2 * roughness - 1, co)
            assert 0 <= approximate <= 1, (roughness, nv, approximate)
            error = abs(reference - approximate)
            worst = max(worst, error)
            assert error < .005, (roughness, nv, reference, approximate)
            cases += 1
    print(f'PASS {cases} hemisphere integrals; max absolute error {worst:.6f}')


if __name__ == '__main__':
    main()
