"""Generate the test PKI for verify-full (dev-only; outputs are committed).

root (RSA 2048) -> inter (EC P-384, signed sha256WithRSA) -> leaf (EC P-256, ecdsa-with-SHA384)
leaf_rsa: RSA leaf for servers that need RSA certificates (SQL Server).
Variants: leaf_cn (no SAN), leaf_expired, leaf_wronghost, leaf_critical (unknown critical
extension), leaf_pss (RSA, signed by root with RSA-PSS), other_root (unrelated CA).
Also signature vectors for PKCS#1 v1.5 and P-384 ECDSA.
"""
import datetime, ipaddress, json, pathlib
from cryptography import x509
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID, ObjectIdentifier
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, ec, padding

out = pathlib.Path(__file__).parent
now = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
far = now + datetime.timedelta(days=365 * 50)


def name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def save_key(k, fn):
    (out / fn).write_bytes(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))


def save(cert, fn):
    (out / fn).write_bytes(cert.public_bytes(serialization.Encoding.PEM))


def build(subject, issuer, pub, issuer_key, *, ca=False, san=None, eku=True, before=now, after=far, extra=(), alg=hashes.SHA256(), pss=False):
    b = (x509.CertificateBuilder().subject_name(name(subject)).issuer_name(name(issuer))
         .public_key(pub).serial_number(x509.random_serial_number())
         .not_valid_before(before).not_valid_after(after))
    if ca:
        b = b.add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        b = b.add_extension(x509.KeyUsage(digital_signature=True, key_cert_sign=True, crl_sign=True, content_commitment=False,
                                          key_encipherment=False, data_encipherment=False, key_agreement=False,
                                          encipher_only=False, decipher_only=False), critical=True)
    else:
        b = b.add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        if eku:
            b = b.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    if san:
        b = b.add_extension(x509.SubjectAlternativeName(san), critical=False)
    for e, crit in extra:
        b = b.add_extension(e, critical=crit)
    if pss:
        return b.sign(issuer_key, alg, rsa_padding=padding.PSS(mgf=padding.MGF1(alg), salt_length=alg.digest_size))
    return b.sign(issuer_key, alg)


SAN = [x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]

root_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
root = build("dbdash test root", "dbdash test root", root_key.public_key(), root_key, ca=True)
inter_key = ec.generate_private_key(ec.SECP384R1())
inter = build("dbdash test intermediate", "dbdash test root", inter_key.public_key(), root_key, ca=True)
leaf_key = ec.generate_private_key(ec.SECP256R1())
leaf = build("dbdash leaf", "dbdash test intermediate", leaf_key.public_key(), inter_key, san=SAN, alg=hashes.SHA384())
leaf_cn = build("localhost", "dbdash test intermediate", leaf_key.public_key(), inter_key, alg=hashes.SHA384())
leaf_expired = build("dbdash expired", "dbdash test intermediate", leaf_key.public_key(), inter_key, san=SAN, alg=hashes.SHA384(),
                     before=datetime.datetime(2019, 1, 1, tzinfo=datetime.timezone.utc), after=datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc))
leaf_wronghost = build("dbdash wrong host", "dbdash test intermediate", leaf_key.public_key(), inter_key, san=[x509.DNSName("example.com")], alg=hashes.SHA384())
leaf_critical = build("dbdash critical", "dbdash test intermediate", leaf_key.public_key(), inter_key, san=SAN, alg=hashes.SHA384(),
                      extra=[(x509.UnrecognizedExtension(ObjectIdentifier("1.3.6.1.4.1.99999.1"), b"\x05\x00"), True)])
rsa_leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
# SQL Server only accepts strict (TDS 8) connections with a certificate for its host name.
leaf_rsa = build("dbdash-mssql", "dbdash test intermediate", rsa_leaf_key.public_key(), inter_key,
                 san=SAN + [x509.DNSName("dbdash-mssql")], alg=hashes.SHA384())
pss_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
leaf_pss = build("dbdash pss", "dbdash test root", pss_key.public_key(), root_key, san=SAN, pss=True)
other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
other_root = build("dbdash other root", "dbdash other root", other_key.public_key(), other_key, ca=True)

for k, fn in [(root_key, "root.key"), (inter_key, "inter.key"), (leaf_key, "leaf.key"), (pss_key, "leaf_pss.key"), (rsa_leaf_key, "leaf_rsa.key")]:
    save_key(k, fn)
for c, fn in [(root, "root.pem"), (inter, "inter.pem"), (leaf, "leaf.pem"), (leaf_cn, "leaf_cn.pem"), (leaf_expired, "leaf_expired.pem"),
              (leaf_wronghost, "leaf_wronghost.pem"), (leaf_critical, "leaf_critical.pem"), (leaf_pss, "leaf_pss.pem"), (other_root, "other_root.pem"),
              (leaf_rsa, "leaf_rsa.pem")]:
    save(c, fn)
# Chain files for servers: leaf followed by the intermediate.
(out / "leaf_chain.pem").write_bytes(leaf.public_bytes(serialization.Encoding.PEM) + inter.public_bytes(serialization.Encoding.PEM))
# CA bundle with the intermediate, for servers that only send their leaf (SQL Server).
(out / "ca_bundle.pem").write_bytes(root.public_bytes(serialization.Encoding.PEM) + inter.public_bytes(serialization.Encoding.PEM))
(out / "leaf_rsa_chain.pem").write_bytes(leaf_rsa.public_bytes(serialization.Encoding.PEM) + inter.public_bytes(serialization.Encoding.PEM))

msg = b"dbdash signature test"
vectors = {
    "msg": msg.decode(),
    "pkcs1_sha256": root_key.sign(msg, padding.PKCS1v15(), hashes.SHA256()).hex(),
    "pkcs1_sha384": root_key.sign(msg, padding.PKCS1v15(), hashes.SHA384()).hex(),
    "pkcs1_sha512": root_key.sign(msg, padding.PKCS1v15(), hashes.SHA512()).hex(),
    "ecdsa_p384_sha384": inter_key.sign(msg, ec.ECDSA(hashes.SHA384())).hex(),
}
(out / "vectors.json").write_text(json.dumps(vectors, indent=1) + "\n")
print("ok")
