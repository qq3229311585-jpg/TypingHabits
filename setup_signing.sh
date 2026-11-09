#!/bin/bash
# 创建本机专用的固定签名身份,让重装 App 后「输入监控」授权不再失效。
# 证书与密钥只存在独立钥匙串 ~/Library/Keychains/typinghabits-dev.keychain-db(空密码,仅用于本地开发签名),不进仓库。
set -e
KC="$HOME/Library/Keychains/typinghabits-dev.keychain-db"
NAME="TypingHabits Local Dev"
if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then echo "签名身份已存在"; exit 0; fi
T=$(mktemp -d)
cat > $T/o.cnf <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout $T/k.pem -out $T/c.pem -days 3650 -config $T/o.cnf 2>/dev/null
openssl pkcs12 -export -inkey $T/k.pem -in $T/c.pem -out $T/id.p12 -passout pass:tmp -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
[ -f "$KC" ] || security create-keychain -p "" "$KC"
security unlock-keychain -p "" "$KC"
security set-keychain-settings "$KC"
security import $T/id.p12 -k "$KC" -P tmp -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null
rm -rf $T
security find-identity -p codesigning "$KC"
