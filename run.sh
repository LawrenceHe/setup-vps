#!/usr/bin/env bash
set -Eeuo pipefail

MAVEN_VERSION="3.9.9"
export DEBIAN_FRONTEND=noninteractive

log(){ printf '\n==> %s\n' "$*"; }
ok(){ printf '✓ %s\n' "$*"; }
die(){ printf '✗ %s\n' "$*" >&2; exit 1; }
trap 'printf "✗ Failed at line %s\n" "$LINENO" >&2' ERR

[[ $EUID -ne 0 ]] || die "Run as a normal Ubuntu user with sudo privileges."
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Ubuntu only."

case "$(uname -m)" in
  x86_64) ARCH=amd64; LG_ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64; LG_ARCH=arm64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

# sudo -v 在 sudo-rs（Ubuntu 26.04 默认）下只要命中任何一条非 NOPASSWD 规则（如 %sudo）就要密码，
# 而云主机默认用户没有密码；先试免密，失败再交互。
sudo -n true 2>/dev/null || sudo -v || die "sudo is not usable for $(id -un)."
log "Ubuntu: ${PRETTY_NAME}; architecture: ${ARCH}"
sudo apt-get update -y

apt_pkg() {
  local p="$1"
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then
    sudo apt-get install -y --only-upgrade "$p"
  else
    sudo apt-get install -y "$p"
  fi
}

log "Base packages"
for p in ca-certificates curl wget unzip zip tar gzip xz-utils gnupg jq rsync lsof build-essential ncurses-bin git tmux mosh openjdk-21-jdk mysql-client postgresql-client neovim btop; do
  apt_pkg "$p"
done

log "Maven ${MAVEN_VERSION}"
CURRENT_MAVEN="$(mvn -version 2>/dev/null | head -1 | awk '{print $3}' || true)"
if [[ "$CURRENT_MAVEN" != "$MAVEN_VERSION" ]]; then
  tmp="$(mktemp -d)"
  curl -fL "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o "$tmp/maven.tgz"
  sudo rm -rf "/opt/apache-maven-${MAVEN_VERSION}"
  sudo tar -xzf "$tmp/maven.tgz" -C /opt
  sudo ln -sfn "/opt/apache-maven-${MAVEN_VERSION}" /opt/maven
  sudo ln -sfn /opt/maven/bin/mvn /usr/local/bin/mvn
  rm -rf "$tmp"
else
  ok "Maven already ${MAVEN_VERSION}"
fi

log "uv + latest stable Python"
export PATH="$HOME/.local/bin:$PATH"
if command -v uv >/dev/null; then
  uv self update || true
else
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
uv python install --default

log "nvm + latest Node.js LTS"
export NVM_DIR="$HOME/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  NVM_VERSION="$(git ls-remote --tags --refs https://github.com/nvm-sh/nvm.git | awk -F/ '{print $3}' | sort -V | tail -1)"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"
# nvm 与 ~/.npmrc 里的 prefix/globalconfig 不兼容（nvm use 直接返回 11）
if [[ -f "$HOME/.npmrc" ]] && grep -qE '^[[:space:]]*(prefix|globalconfig)[[:space:]]*=' "$HOME/.npmrc"; then
  cp "$HOME/.npmrc" "$HOME/.npmrc.bak.$(date +%s)"
  sed -i -E '/^[[:space:]]*(prefix|globalconfig)[[:space:]]*=/d' "$HOME/.npmrc"
  ok "Removed prefix/globalconfig from ~/.npmrc (backup kept)"
fi
nvm install --lts
nvm alias default 'lts/*'
nvm use default

log "pi coding agent"
# https://github.com/earendil-works/pi — installs into the nvm-managed Node
npm install -g --ignore-scripts @earendil-works/pi-coding-agent

log "herdr"
# https://github.com/herdrdev/herdr — official installer, puts the binary in ~/.local/bin
curl -fsSL https://herdr.dev/install.sh | sh

log "mosh firewall"
if command -v ufw >/dev/null && sudo ufw status | grep -q '^Status: active'; then
  sudo ufw allow 60000:61000/udp
else
  ok "ufw not active; if the provider has a cloud firewall, open UDP 60000-61000 for mosh"
fi

log "Docker CE"
if command -v docker >/dev/null; then
  sudo apt-get update -y
  pkgs=()
  for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    apt-cache show "$p" >/dev/null 2>&1 && pkgs+=("$p")
  done
  ((${#pkgs[@]})) && sudo apt-get install -y "${pkgs[@]}"
else
  curl -fsSL https://get.docker.com | sudo sh
fi
if getent group docker >/dev/null && ! id -nG | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$(id -un)"
  DOCKER_RELOGIN=1
fi

log "kubectl latest stable"
KUBE_LATEST="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
KUBE_CURRENT="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' || true)"
if [[ "$KUBE_CURRENT" != "$KUBE_LATEST" ]]; then
  tmp="$(mktemp -d)"
  curl -fL "https://dl.k8s.io/release/${KUBE_LATEST}/bin/linux/${ARCH}/kubectl" -o "$tmp/kubectl"
  curl -fL "https://dl.k8s.io/release/${KUBE_LATEST}/bin/linux/${ARCH}/kubectl.sha256" -o "$tmp/kubectl.sha256"
  echo "$(cat "$tmp/kubectl.sha256")  $tmp/kubectl" | sha256sum --check
  sudo install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
else
  ok "kubectl already ${KUBE_LATEST}"
fi

log "Alibaba Cloud CLI"
# Official installer installs/updates the CLI and detects Linux architecture.
sudo bash -c "$(curl -fsSL https://aliyuncli.alicdn.com/install.sh)"

log "lazygit latest"
LG_LATEST="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
LG_CURRENT="$(lazygit --version 2>/dev/null | grep -oE 'version=[^,]+' | cut -d= -f2 || true)"
if [[ "$LG_CURRENT" != "$LG_LATEST" ]]; then
  tmp="$(mktemp -d)"
  curl -fL "https://github.com/jesseduffield/lazygit/releases/download/v${LG_LATEST}/lazygit_${LG_LATEST}_linux_${LG_ARCH}.tar.gz" -o "$tmp/lazygit.tgz"
  tar -xzf "$tmp/lazygit.tgz" -C "$tmp" lazygit
  sudo install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
  rm -rf "$tmp"
else
  ok "lazygit already ${LG_LATEST}"
fi

log "Ghostty terminfo"
tmp="$(mktemp)"
cat >"$tmp" <<'TERMINFO'
# Reconstructed via infocmp from file: /Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty
xterm-ghostty|ghostty|Ghostty,
        am, bce, ccc, hs, km, mc5i, mir, msgr, npc, xenl, AX, Su, Tc, XT, fullkbd,
        colors#256, cols#80, it#8, lines#24, pairs#32767,
        acsc=++\,\,--..00``aaffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~,
        bel=^G, blink=\E[5m, bold=\E[1m, cbt=\E[Z, civis=\E[?25l,
        clear=\E[H\E[2J, cnorm=\E[?12l\E[?25h, cr=^M,
        csr=\E[%i%p1%d;%p2%dr, cub=\E[%p1%dD, cub1=^H,
        cud=\E[%p1%dB, cud1=^J, cuf=\E[%p1%dC, cuf1=\E[C,
        cup=\E[%i%p1%d;%p2%dH, cuu=\E[%p1%dA, cuu1=\E[A,
        cvvis=\E[?12;25h, dch=\E[%p1%dP, dch1=\E[P, dim=\E[2m,
        dl=\E[%p1%dM, dl1=\E[M, dsl=\E]2;\007, ech=\E[%p1%dX,
        ed=\E[J, el=\E[K, el1=\E[1K, flash=\E[?5h$<100/>\E[?5l,
        fsl=^G, home=\E[H, hpa=\E[%i%p1%dG, ht=^I, hts=\EH,
        ich=\E[%p1%d@, ich1=\E[@, il=\E[%p1%dL, il1=\E[L, ind=^J,
        indn=\E[%p1%dS,
        initc=\E]4;%p1%d;rgb\:%p2%{255}%*%{1000}%/%2.2X/%p3%{255}%*%{1000}%/%2.2X/%p4%{255}%*%{1000}%/%2.2X\E\\,
        invis=\E[8m, kDC=\E[3;2~, kEND=\E[1;2F, kHOM=\E[1;2H,
        kIC=\E[2;2~, kLFT=\E[1;2D, kNXT=\E[6;2~, kPRV=\E[5;2~,
        kRIT=\E[1;2C, kbs=\177, kcbt=\E[Z, kcub1=\EOD, kcud1=\EOB,
        kcuf1=\EOC, kcuu1=\EOA, kdch1=\E[3~, kend=\EOF, kent=\EOM,
        kf1=\EOP, kf10=\E[21~, kf11=\E[23~, kf12=\E[24~,
        kf13=\E[1;2P, kf14=\E[1;2Q, kf15=\E[1;2R, kf16=\E[1;2S,
        kf17=\E[15;2~, kf18=\E[17;2~, kf19=\E[18;2~, kf2=\EOQ,
        kf20=\E[19;2~, kf21=\E[20;2~, kf22=\E[21;2~,
        kf23=\E[23;2~, kf24=\E[24;2~, kf25=\E[1;5P, kf26=\E[1;5Q,
        kf27=\E[1;5R, kf28=\E[1;5S, kf29=\E[15;5~, kf3=\EOR,
        kf30=\E[17;5~, kf31=\E[18;5~, kf32=\E[19;5~,
        kf33=\E[20;5~, kf34=\E[21;5~, kf35=\E[23;5~,
        kf36=\E[24;5~, kf37=\E[1;6P, kf38=\E[1;6Q, kf39=\E[1;6R,
        kf4=\EOS, kf40=\E[1;6S, kf41=\E[15;6~, kf42=\E[17;6~,
        kf43=\E[18;6~, kf44=\E[19;6~, kf45=\E[20;6~,
        kf46=\E[21;6~, kf47=\E[23;6~, kf48=\E[24;6~,
        kf49=\E[1;3P, kf5=\E[15~, kf50=\E[1;3Q, kf51=\E[1;3R,
        kf52=\E[1;3S, kf53=\E[15;3~, kf54=\E[17;3~,
        kf55=\E[18;3~, kf56=\E[19;3~, kf57=\E[20;3~,
        kf58=\E[21;3~, kf59=\E[23;3~, kf6=\E[17~, kf60=\E[24;3~,
        kf61=\E[1;4P, kf62=\E[1;4Q, kf63=\E[1;4R, kf7=\E[18~,
        kf8=\E[19~, kf9=\E[20~, khome=\EOH, kich1=\E[2~,
        kind=\E[1;2B, kmous=\E[<, knp=\E[6~, kpp=\E[5~,
        kri=\E[1;2A, oc=\E]104\007, op=\E[39;49m, rc=\E8,
        rep=%p1%c\E[%p2%{1}%-%db, rev=\E[7m, ri=\EM,
        rin=\E[%p1%dT, ritm=\E[23m, rmacs=\E(B, rmam=\E[?7l,
        rmcup=\E[?1049l, rmir=\E[4l, rmkx=\E[?1l\E>, rmso=\E[27m,
        rmul=\E[24m, rs1=\E]\E\\\Ec, sc=\E7,
        setab=\E[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m,
        setaf=\E[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m,
        sgr=%?%p9%t\E(0%e\E(B%;\E[0%?%p6%t;1%;%?%p5%t;2%;%?%p2%t;4%;%?%p1%p3%|%t;7%;%?%p4%t;5%;%?%p7%t;8%;m,
        sgr0=\E(B\E[m, sitm=\E[3m, smacs=\E(0, smam=\E[?7h,
        smcup=\E[?1049h, smir=\E[4h, smkx=\E[?1h\E=, smso=\E[7m,
        smul=\E[4m, tbc=\E[3g, tsl=\E]2;, u6=\E[%i%d;%dR, u7=\E[6n,
        u8=\E[?%[;0123456789]c, u9=\E[c, vpa=\E[%i%p1%dd,
        BD=\E[?2004l, BE=\E[?2004h, Clmg=\E[s,
        Cmg=\E[%i%p1%d;%p2%ds, Dsmg=\E[?69l, E3=\E[3J,
        Enmg=\E[?69h, Ms=\E]52;%p1%s;%p2%s\007, PE=\E[201~,
        PS=\E[200~, RV=\E[>c, Se=\E[2 q,
        Setulc=\E[58\:2\:\:%p1%{65536}%/%d\:%p1%{256}%/%{255}%&%d\:%p1%{255}%&%d%;m,
        Smulx=\E[4\:%p1%dm, Ss=\E[%p1%d q,
        Sync=\E[?2026%?%p1%{1}%-%tl%eh%;,
        XM=\E[?1006;1000%?%p1%{1}%=%th%el%;, XR=\E[>0q,
        fd=\E[?1004l, fe=\E[?1004h, kDC3=\E[3;3~, kDC4=\E[3;4~,
        kDC5=\E[3;5~, kDC6=\E[3;6~, kDC7=\E[3;7~, kDN=\E[1;2B,
        kDN3=\E[1;3B, kDN4=\E[1;4B, kDN5=\E[1;5B, kDN6=\E[1;6B,
        kDN7=\E[1;7B, kEND3=\E[1;3F, kEND4=\E[1;4F,
        kEND5=\E[1;5F, kEND6=\E[1;6F, kEND7=\E[1;7F,
        kHOM3=\E[1;3H, kHOM4=\E[1;4H, kHOM5=\E[1;5H,
        kHOM6=\E[1;6H, kHOM7=\E[1;7H, kIC3=\E[2;3~, kIC4=\E[2;4~,
        kIC5=\E[2;5~, kIC6=\E[2;6~, kIC7=\E[2;7~, kLFT3=\E[1;3D,
        kLFT4=\E[1;4D, kLFT5=\E[1;5D, kLFT6=\E[1;6D,
        kLFT7=\E[1;7D, kNXT3=\E[6;3~, kNXT4=\E[6;4~,
        kNXT5=\E[6;5~, kNXT6=\E[6;6~, kNXT7=\E[6;7~,
        kPRV3=\E[5;3~, kPRV4=\E[5;4~, kPRV5=\E[5;5~,
        kPRV6=\E[5;6~, kPRV7=\E[5;7~, kRIT3=\E[1;3C,
        kRIT4=\E[1;4C, kRIT5=\E[1;5C, kRIT6=\E[1;6C,
        kRIT7=\E[1;7C, kUP=\E[1;2A, kUP3=\E[1;3A, kUP4=\E[1;4A,
        kUP5=\E[1;5A, kUP6=\E[1;6A, kUP7=\E[1;7A, kxIN=\E[I,
        kxOUT=\E[O, rmxx=\E[29m, rv=\E\\[[0-9]+;[0-9]+;[0-9]+c,
        setrgbb=\E[48\:2\:%p1%d\:%p2%d\:%p3%dm,
        setrgbf=\E[38\:2\:%p1%d\:%p2%d\:%p3%dm, smxx=\E[9m,
        xm=\E[<%i%p3%d;%p1%d;%p2%d;%?%p4%tM%em%;,
        xr=\EP>\\|[ -~]+a\E\\,
TERMINFO
sudo tic -x -o /usr/share/terminfo "$tmp"
rm -f "$tmp"
infocmp -x xterm-ghostty >/dev/null
ok "xterm-ghostty installed globally"

log "Versions"
git --version
java -version 2>&1 | head -1
mvn -version | head -1
uv --version
python3 --version || true
node --version
npm --version
docker --version
kubectl version --client 2>/dev/null | head -1
aliyun version 2>/dev/null || true
mysql --version
psql --version
nvim --version | head -1
lazygit --version
btop --version | head -1
tmux -V
mosh --version 2>&1 | head -1
pi --version
herdr --version

printf '\n✓ VPS setup complete.\n'
if [[ "${DOCKER_RELOGIN:-0}" == 1 ]]; then
  printf 'NOTE: Log out and SSH back in once so Docker group membership takes effect.\n'
fi
