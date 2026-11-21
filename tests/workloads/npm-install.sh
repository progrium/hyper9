# npm packs a local package, installs the tarball offline into a new
# project, which runs its postinstall script in a child node, and runs a
# script that requires it.
# expect: 11.6.4
# expect: hello, npm
# expect: postinstall: yes
# timeout: 300
export HOME=/tmp/home
npm --version
cp -r /mnt/term/cwd/fixtures/npm-greet /tmp/npm-greet
cd /tmp/npm-greet && npm pack --silent >/dev/null
mkdir /tmp/app && cd /tmp/app && npm init -y >/dev/null
npm install --offline --no-audit --no-fund /tmp/npm-greet/npm-greet-1.0.0.tgz >/dev/null
npm pkg set scripts.greet="node -e \"console.log(require('npm-greet')('npm'))\""
npm run --silent greet
echo "postinstall: $(cat node_modules/npm-greet/installed)"
