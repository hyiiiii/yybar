#!/bin/bash
# 在登录钥匙串里创建「yybar Local Code Signing」自签代码签名证书(20 年有效，只用于代码签名)。
# 已存在时什么都不做。私钥只导入钥匙串，临时文件随即删除。
set -euo pipefail
NAME="yybar Local Code Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "证书已存在：$NAME"
  exit 0
fi
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -days 7300 -config "$DIR/cert.cnf"
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout pass:"$PASS" -name "$NAME"
security import "$DIR/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "已创建：$NAME"
