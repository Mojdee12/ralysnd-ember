#!/usr/bin/env bash
# Contract-suite runner (2042 blocking gate): builds the real Go
# service for this host, stages a fixture app root with fake engine
# binaries, starts the service console, and runs contract-suite.cjs
# against it. Exit code propagates — a red suite fails the build.
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$PWD"
FIX="$(mktemp -d /tmp/ember-contract-XXXXXX)"
cleanup() {
  [ -n "${SVC_PID:-}" ] && kill "$SVC_PID" 2>/dev/null
  rm -rf "$FIX"
}
trap cleanup EXIT

source "$HOME/workspace/ember-app/toolchain/env.sh"
export PATH="$HOME/workspace/ember-app/toolchain/go1.27.3/bin:$PATH" GOTOOLCHAIN=local

mkdir -p "$FIX/app/core" "$FIX/app/xray"
(cd core && go build -o "$FIX/app/core/ember-service" ./cmd/ember-service/) || { echo "service build failed"; exit 2; }

# Fake xray.exe: reads stdin to EOF, saves it verbatim, then serves
# the SOCKS port — the exact behaviour the contract cares about.
cat > "$FIX/app/xray/xray.exe" <<'EOF'
#!/usr/bin/env node
const fs = require('fs'), net = require('net');
const chunks = [];
process.stdin.on('data', c => chunks.push(c));
process.stdin.on('end', () => {
  fs.writeFileSync(process.env.FAKE_XRAY_OUT, Buffer.concat(chunks));
  net.createServer(s => { s.end(); }).listen(10808, '127.0.0.1');
});
setInterval(() => {}, 1000);
EOF
# Fake TUN bridge: speaks the helper's UP line protocol, then idles.
cat > "$FIX/app/core/ember-tun-bridge.exe" <<'EOF'
#!/usr/bin/env node
console.log('UP contract0 index=1 luid=1 proxy=127.0.0.1:10808');
setInterval(() => {}, 1000);
EOF
chmod +x "$FIX/app/xray/xray.exe" "$FIX/app/core/ember-tun-bridge.exe"

export CONTRACT_FIXTURE_ROOT="$FIX/app"
export CONTRACT_RECEIVED_FILE="$FIX/received-config.json"
export FAKE_XRAY_OUT="$CONTRACT_RECEIVED_FILE"

"$FIX/app/core/ember-service" console > "$FIX/service.log" 2>&1 &
SVC_PID=$!
for i in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/47832) 2>/dev/null && { exec 3>&- 3<&-; break; }
  sleep 0.2
done

node electron/tools/contract-suite.cjs
RC=$?
if [ $RC -ne 0 ]; then echo "--- service log:"; cat "$FIX/service.log"; fi
exit $RC
