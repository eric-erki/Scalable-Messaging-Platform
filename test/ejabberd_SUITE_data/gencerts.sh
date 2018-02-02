#!/bin/sh
# Update openssl.cnf if needed (in particular section [alt_names] and option
# crlDistributionPoints in sections [v3_ca] and [usr_cert]

rm -rf ssl
mkdir -p ssl/newcerts
touch ssl/index.txt
if [ -n "$1" ]; then
    sed "s/localhost:5280/localhost:${1}/" openssl.cnf > openssl-copy.cnf
else
    cp openssl.cnf openssl-copy.cnf
fi
echo 01 > ssl/serial
echo 1000 > ssl/crlnumber
openssl genrsa -out ssl/client.key
openssl genrsa -out ssl/rev-client.key
openssl req -new -key ssl/client.key -out ssl/client.csr -config openssl-copy.cnf -batch -subj /C=AU/ST=Some-State/O=Internet\ Widgits\ Pty\ Ltd/CN=active
openssl req -new -key ssl/rev-client.key -out ssl/rev-client.csr -config openssl-copy.cnf -batch -subj  /C=AU/ST=Some-State/O=Internet\ Widgits\ Pty\ Ltd/CN=revoked
openssl ca -keyfile ca.key -cert ca.pem -in ssl/client.csr -out ssl/client.crt -config openssl-copy.cnf -days 10000 -batch -notext
openssl ca -keyfile ca.key -cert ca.pem -in ssl/rev-client.csr -out ssl/rev-client.crt -config openssl-copy.cnf -days 10000 -batch -notext
openssl ca -keyfile ca.key -cert ca.pem -revoke ssl/rev-client.crt -config openssl-copy.cnf
openssl ca -keyfile ca.key -cert ca.pem -gencrl -out ssl/crl.pem -config openssl-copy.cnf
openssl crl -in ssl/crl.pem -outform der > crl.der
cat ssl/client.crt > cert.pem
cat ssl/client.key >> cert.pem
cat ssl/rev-client.crt > rev-cert.pem
cat ssl/rev-client.key >> rev-cert.pem
rm -rf ssl
