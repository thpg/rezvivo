"""Bake small, seamless ambience loops and original REZVIVO interface/ride cues.

Run manually; the client never generates or downloads audio while riding.
Sources are CC0. Original downloads are kept outside the shipped data folder.
"""
import hashlib
import json
import math
from pathlib import Path
import tempfile
import urllib.request

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, butter, sosfilt

ROOT = Path(__file__).resolve().parents[1] / 'data/audio'
CACHE = Path(tempfile.gettempdir()) / 'rezvivo-audio-source'
RATE = 32000
SOURCES = {
    'forest': ('isaiah658', 'https://opengameart.org/content/ambient-bird-sounds',
               ['https://opengameart.org/sites/default/files/birds-isaiah658_0.ogg']),
    'sea': ('jasinski / qubodup', 'https://opengameart.org/content/beach-ocean-waves',
            ['https://opengameart.org/sites/default/files/wave_%02d_cc0-18363__jasinski__alkaibeach.flac' % i for i in range(1, 5)]),
    'highway': ('IgnasD', 'https://opengameart.org/content/high-traffic-road-sounds',
                ['https://opengameart.org/sites/default/files/gatve%20Varniu_2.ogg']),
    'wind': ('Luke.RUSTLTD', 'https://opengameart.org/content/wind1',
             ['https://opengameart.org/sites/default/files/wind1.wav']),
    'city': ('qubodup / jmbphilmes', 'https://freesound.org/people/qubodup/sounds/223093/',
             ['https://cdn.freesound.org/previews/223/223093_71257-hq.mp3']),
}


def source(url):
    path = CACHE / (hashlib.sha256(url.encode()).hexdigest()[:12] + Path(url).suffix)
    if not path.exists():
        with urllib.request.urlopen(url, timeout=45) as response:
            path.write_bytes(response.read())
    x, rate = sf.read(path, dtype='float32', always_2d=True)
    if x.shape[1] == 1:
        x = np.repeat(x, 2, axis=1)
    g = math.gcd(rate, RATE)
    return resample_poly(x[:, :2], RATE // g, rate // g)


def join(a, b, seconds=1.5):
    n = min(int(seconds * RATE), len(a)//4, len(b)//4)
    t = np.linspace(0, 1, n, endpoint=False)[:, None]
    return np.concatenate((a[:-n], a[-n:] * np.cos(t*np.pi/2) + b[:n]*np.sin(t*np.pi/2), b[n:]))


def loop(x):
    # The seam lies inside a crossfade; there is no fade to silence on every lap.
    n = min(2*RATE, len(x)//5)
    t = np.linspace(0, 1, n, endpoint=False)[:, None]
    return np.concatenate((x[n:-n], x[-n:]*np.cos(t*np.pi/2) + x[:n]*np.sin(t*np.pi/2)))


def save(name, x, ambient=False):
    x = x - np.mean(x, axis=0)
    rms = np.sqrt(np.mean(x*x))
    x *= min(0.105 / max(rms, 1e-6), 0.83 / max(np.max(np.abs(x)), 1e-6))
    ext = '.ogg' if ambient else '.wav'
    path = ROOT / (name + ext)
    # libsndfile's Vorbis encoder can exhaust the Windows thread stack if
    # handed a long float64 block. Stream bounded float32 blocks offline.
    x = np.asarray(x, dtype=np.float32)
    with sf.SoundFile(path, 'w', RATE, channels=1 if x.ndim == 1 else x.shape[1],
                      subtype='VORBIS' if ambient else 'PCM_16') as output:
        for first in range(0, len(x), 4096):
            output.write(x[first:first+4096])
    print(name, round(len(x)/RATE, 2), 'sec', path.stat().st_size, 'bytes')


def tone(freq, duration):
    t = np.arange(int(RATE*duration))/RATE
    env = np.minimum(1, t/0.009) * np.minimum(1, (duration-t)/0.035)
    return env*(np.sin(2*np.pi*freq*t) + 0.10*np.sin(4*np.pi*freq*t))


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(exist_ok=True)
    credits = []
    for name, (author, page, urls) in SOURCES.items():
        parts = [source(url) for url in urls]
        x = parts[0]
        for part in parts[1:]:
            x = join(x, part)
        x = x[:RATE*48]
        # Remove DC/handling rumble without removing the character of the road.
        x = sosfilt(butter(2, 65, 'highpass', fs=RATE, output='sos'), x, axis=0)
        save(name, loop(x), True)
        credits.append(dict(file=name+'.ogg', author=author, source=page,
                            downloads=urls, license='CC0-1.0',
                            changes='Trimmed, resampled, filtered, level adjusted and crossfaded for seamless looping.'))
    save('countdown', tone(660, .12))
    save('interval-start', tone(990, .32))
    rng = np.random.default_rng(20260926)
    t = np.arange(int(.045*RATE))/RATE
    save('click', np.exp(-t*125) * (0.75*np.sin(2*np.pi*1250*t) + .2*rng.normal(size=len(t))) * np.minimum(1,t/.0015))
    for name, freq in [('wheel-front', 100), ('wheel-rear', 78)]:
        t = np.arange(int(.17*RATE))/RATE
        noise = sosfilt(butter(2, 800, fs=RATE, output='sos'), rng.normal(size=len(t)))
        x = (np.sin(2*np.pi*(freq*t+15*t*np.exp(-t*28)))*np.exp(-t*35) + .45*noise*np.exp(-t*60))
        save(name, x*np.minimum(1, t/.0018))
    for name in ['click', 'countdown', 'interval-start', 'wheel-front', 'wheel-rear']:
        credits.append(dict(file=name+'.wav', author='REZVIVO', source='tools/build_audio.py',
                            license='Original project asset; no external samples'))
    (ROOT/'credits.json').write_text(json.dumps(credits, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    main()
