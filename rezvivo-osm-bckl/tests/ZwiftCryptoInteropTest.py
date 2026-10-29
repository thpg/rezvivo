"""Independent peer: verify the Pascal ECDH/HKDF/CCM implementation on real
OpenSSL primitives, including authentication failure and replay rejection.
Usage: python tests/ZwiftCryptoInteropTest.py path/to/ZwiftCryptoProbe.exe
Requires the test-only Python cryptography package; the game does not.
"""
import subprocess
import sys
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESCCM

for run in range(3):
    p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    try:
        request = bytes.fromhex(p.stdout.readline().strip())
        assert len(request) == 72 and request[:8] == b'RideOn\x01\x02', request
        ours = ec.generate_private_key(ec.SECP256R1())
        public = ours.public_key().public_bytes(serialization.Encoding.X962,
                                                serialization.PublicFormat.UncompressedPoint)[1:]
        peer = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), b'\x04' + request[8:])
        secret = ours.exchange(ec.ECDH(), peer)
        material = HKDF(algorithm=hashes.SHA256(), length=36,
                        salt=public + request[8:], info=b'').derive(secret)
        p.stdin.write((b'RideOn\x00\x09' + public).hex() + '\n'); p.stdin.flush()
        assert p.stdout.readline().strip() == 'READY'
        ccm = AESCCM(material[:32], tag_length=4)
        def packet(count, payload):
            counter = count.to_bytes(4, 'little')
            return counter + ccm.encrypt(material[32:] + counter, bytes.fromhex(payload), None)
        press = '07080010011801200128013001380040004800'
        release = '07080010011801200128013001380140004800'
        good = packet(1, press)
        bad = bytearray(packet(2, release)); bad[-1] ^= 1
        cases = [(good, 'OK 1'), (good, 'REJECT'), (bad, 'REJECT'),
                 (packet(2, release), 'OK 1'), (packet(3, press), 'OK 2')]
        for wire, expected in cases:
            p.stdin.write(wire.hex() + '\n'); p.stdin.flush()
            actual = p.stdout.readline().strip()
            assert actual == expected, (actual, expected)
        assert p.wait(timeout=5) == 0, p.stderr.read()
    finally:
        if p.poll() is None: p.kill(); p.wait(timeout=5)
print('PASS Zwift crypto: 3 fresh ECDH sessions; HKDF, CCM, forged MAC and replay checks')
