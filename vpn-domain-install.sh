#!/bin/sh
#
# Copyright (c) 2026 Albert Sayapov
# SPDX-License-Identifier: MIT
#
# VPN Domains 3.0.2 - standalone installer for Asuswrt-Merlin.
# One repository file. All installed assets are embedded below.
# install: fresh installation OR WebUI-only repair of an existing backend.
# configure-vpn: explicit WireGuard change / explicitly confirmed migration.
# status | uninstall | purge --yes
# No OpenVPN selection. No per-network selection. IPv4 only.
set -u
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/opt/sbin:/opt/bin"
LC_ALL=C
export PATH LC_ALL
umask 022
DIR="/jffs/addons/vpn-domain"
LIST="/jffs/configs/vpn-domain-allowlist.txt"
CONF="/jffs/configs/vpn-domain-routing.conf"
CFG="/jffs/configs/vpn-domain-settings.conf"
MANAGED="$DIR/.managed-v3"
OLD_MANAGED="$DIR/.managed-v2"
WEB="/tmp/vpdomain-webui"
VERSION="3.0.2"
BACKUP="/jffs/vpn-domain-backups/$(date +%Y%m%d-%H%M%S)-$$"
WORK=""
LOCKED=0
TX_ACTIVE=0
REFRESH_LOCKED=0
DNS_TOUCHED=0
HEALTH_WAS=0
log() { printf '%s\n' "$*"; logger -t vpn-domain-install "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap cleanup 0
trap 'exit 1' 1 2 15
require_root() {
    effective_uid="$(awk '$1 == "Uid:" {print $3; exit}' /proc/self/status 2>/dev/null)"

    case "$effective_uid" in
        0) ;;
        '') die "Cannot determine effective UID from /proc/self/status." ;;
        *) die "Run as root." ;;
    esac

    [ -d /jffs ] && [ -w /jffs ] || die "/jffs is not writable."
}
lock_install() {
    mkdir /tmp/vpn-domain-install.lock 2>/dev/null || die 'Another installer is running (or its lock needs inspection).'
    LOCKED=1
}
preflight_webui() {
    [ -r /usr/sbin/helper.sh ] || die 'Asuswrt-Merlin helper.sh is missing.'
    [ -x /usr/bin/flock ] || die '/usr/bin/flock is missing.'
    [ -x /opt/bin/base64 ] || die 'Entware base64 is unavailable. Start/install Entware first.'
    [ -f /www/require/modules/menuTree.js ] || die 'Router WebUI menu is unavailable.'
    grep -Eq 'Advanced_VLAN_Switch_Content.asp|Advanced_SwitchCtrl_Content.asp' /www/require/modules/menuTree.js || die 'Supported LAN menu anchor not found.'
    if [ -e /www/user/vpdomain ] && [ ! -L /www/user/vpdomain ]; then die 'WebUI resource path is occupied.'; fi
    if [ -L /www/user/vpdomain ] && [ "$(readlink /www/user/vpdomain)" != "$WEB" ]; then die 'WebUI resource link belongs to another addon.'; fi
}
# Validate balanced marker pairs before touching a shared file.
validate_block() {
    [ -f "$1" ] || return 0
    awk -v b="$2" -v e="$3" '
      $0==b {if(inside)bad=1; inside=1; next}
      $0==e {if(!inside)bad=1; inside=0}
      END {exit (bad || inside)}' "$1" || die "Malformed managed block in $1"
}
strip_block() {
    target="$1"; begin="$2"; end="$3"
    [ -f "$target" ] || return 0
    validate_block "$target" "$begin" "$end"
    awk -v b="$begin" -v e="$end" '$0==b{inside=1;next} $0==e{inside=0;next} !inside{print}' "$target" > "$target.tmp.$$" || return 1
    # Preserve an existing inode: shared files can be used by other integrations.
    cat "$target.tmp.$$" > "$target" || { rm -f "$target.tmp.$$"; return 1; }
    rm -f "$target.tmp.$$"
}
append_block() {
    target="$1"; begin="$2"; end="$3"; content="$4"
    validate_block "$target" "$begin" "$end"
    backup_file "$target"
    if [ ! -f "$target" ]; then printf '%s\n' '#!/bin/sh' > "$target" || return 1; fi
    # Appending after an exit/exec can create a non-working hook. Refuse it.
    awk -v b="$begin" -v e="$end" '
      $0==b{inside=1;next} $0==e{inside=0;next}
      !inside && /^[ \t]*(exit([ \t;]|$)|exec[ \t]+[^0-9])/ {bad=1}
      END{exit bad}' "$target" || die "Top-level-looking exit/exec in $target; inspect hook manually."
    strip_block "$target" "$begin" "$end" || return 1
    { printf '\n%s\n' "$begin"; printf '%s\n' "$content"; printf '%s\n' "$end"; } >> "$target" || return 1
    chmod 755 "$target"
}
backend_exists() {
    [ -x /jffs/scripts/vpn-domain-dnsmasq-generate.sh ] &&
    [ -x /jffs/scripts/vpn-domain-routing.sh ] &&
    [ -x /jffs/scripts/vpn-domain-refresh.sh ] && [ -f "$LIST" ]
}
get_setting() { [ ! -r "$CFG" ] || sed -n "s/^$1=//p" "$CFG"; }
find_table() {
    # Resolve names from the router instead of assuming a numeric mapping.
    for tf in /etc/iproute2/rt_tables /etc/rt_tables; do
        [ -r "$tf" ] || continue
        table_id="$(awk -v n="$1" '$1 !~ /^#/ && $2==n && $1 ~ /^[0-9]+$/ {print $1;exit}' "$tf")"
        if [ -n "$table_id" ]; then printf '%s\n' "$table_id"; return 0; fi
    done
    return 1
}
candidate_ready() {
    ci="$1"; ct="$2"
    ip -4 addr show dev "$ci" 2>/dev/null | grep -q 'inet ' || return 1
    ip -4 route show table "$ct" 2>/dev/null | awk -v iface="$ci" '
      {correct=0;for(i=1;i<NF;i++)if($i=="dev" && $(i+1)==iface)correct=1}
      correct && $1=="default"{full=1}
      correct && $1=="0.0.0.0/1"{lower=1}
      correct && $1=="128.0.0.0/1"{upper=1}
      END{exit !(full || (lower && upper))}' || return 1
    wg show "$ci" latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '
      $2 ~ /^[0-9]+$/ && $2>0 && $2<=now && now-$2<=180{ready=1}
      END{exit !ready}'
}
select_wireguard() {
    [ -r /dev/tty ] && [ -w /dev/tty ] || die 'Interactive terminal required for WireGuard selection.'
    candidates="$WORK/wireguard-candidates"
    : > "$candidates"
    n=0
    printf '\nAvailable ready WireGuard clients (IPv4, full routes, handshake <=180s):\n' > /dev/tty
    for iface in $(wg show interfaces 2>/dev/null); do
        case "$iface" in wgc[1-9]|wgc[1-9][0-9]) ;; *) continue ;; esac
        table="$(find_table "$iface")" || { printf '  %s: table mapping not found; skipped\n' "$iface" > /dev/tty; continue; }
        case "$table" in ''|*[!0-9]*) continue ;; esac
        [ "$table" -gt 0 ] && [ "$table" -lt 253 ] || continue
        if ! candidate_ready "$iface" "$table"; then
            printf '  %s: not ready (IPv4/routes/recent handshake required); skipped\n' "$iface" > /dev/tty
            continue
        fi
        n=$((n+1))
        address="$(ip -4 addr show dev "$iface" | awk '/inet /{print $2;exit}')"
        printf '  %s) %s  IPv4=%s  table=%s\n' "$n" "$iface" "$address" "$table" > /dev/tty
        printf '%s %s\n' "$iface" "$table" >> "$candidates"
    done
    [ "$n" -gt 0 ] || die 'No ready WireGuard client found. Start a wgc client, generate tunnel traffic and retry.'
    while :; do
        printf 'Select WireGuard client [1-%s], or q to cancel: ' "$n" > /dev/tty
        IFS= read -r answer < /dev/tty || die 'Selection cancelled.'
        case "$answer" in q|Q) die 'Cancelled; no installation changes made.' ;; ''|*[!0-9]*) continue ;; esac
        [ "${#answer}" -le 3 ] || continue
        answer="$(printf '%s' "$answer" | sed 's/^0*//')"
        [ -n "$answer" ] && [ "$answer" -ge 1 ] && [ "$answer" -le "$n" ] || continue
        WG_INTERFACE="$(awk -v n="$answer" 'NR==n{print $1}' "$candidates")"
        WG_TABLE="$(awk -v n="$answer" 'NR==n{print $2}' "$candidates")"
        break
    done
}
confirm() {
    printf '\n%s\nType YES to continue: ' "$1" > /dev/tty
    IFS= read -r reply < /dev/tty || die 'Confirmation cancelled.'
    [ "$reply" = YES ] || die 'Cancelled; no configuration changes made.'
}
write_settings() {
    backup_file "$CFG"
    printf '# VPN Domains settings; not a DNS include.\nWG_INTERFACE=%s\nWG_TABLE=%s\n' "$WG_INTERFACE" "$WG_TABLE" > "$CFG.tmp.$$" || die 'Cannot write settings.'
    chmod 600 "$CFG.tmp.$$"
    mv -f "$CFG.tmp.$$" "$CFG" || die 'Cannot install settings.'
}
write_asset() {
    src="$1"; dst="$2"; mode="$3"
    backup_file "$dst"
    cp "$WORK/$src" "$dst.tmp.$$" || die "Cannot stage $dst"
    chmod "$mode" "$dst.tmp.$$" || die "Cannot chmod $dst"
    mv -f "$dst.tmp.$$" "$dst" || die "Cannot install $dst"
}
install_webui() {
    mkdir -p "$DIR" /jffs/scripts || die 'Cannot create addon directories.'
    write_asset VPNDomain.asp "$DIR/VPNDomain.asp" 644
    for asset in mount.sh webui-handler.sh lib.sh; do write_asset "$asset" "$DIR/$asset" 755; done
    append_block /jffs/scripts/services-start '# BEGIN VPDOMAIN WEBUI' '# END VPDOMAIN WEBUI' '(
    sleep 5
    /jffs/addons/vpn-domain/mount.sh >/tmp/vpdomain-webui-mount.log 2>&1
) &' || die 'Cannot update services-start WebUI block.'
    append_block /jffs/scripts/service-event '# BEGIN VPDOMAIN WEBUI' '# END VPDOMAIN WEBUI' 'if [ "${2:-}" = "vpndomain" ]; then
    /jffs/addons/vpn-domain/webui-handler.sh >/tmp/vpdomain-webui-handler.log 2>&1 &
fi' || die 'Cannot update service-event WebUI block.'
    "$DIR/mount.sh" || die "WebUI mount failed. Backup: $BACKUP"
    page="$(cat "$DIR/page" 2>/dev/null)"
    case "$page" in user[0-9].asp|user[0-9][0-9].asp) ;; *) die 'Invalid mounted WebUI page.' ;; esac
    grep -q 'value="Save and apply"' "/www/user/$page" || die 'Live WebUI verification failed.'
}
install_backend_files() {
    for asset in vpn-domain-dnsmasq-generate.sh vpn-domain-routing.sh vpn-domain-refresh.sh; do
        write_asset "$asset" "/jffs/scripts/$asset" 755
    done
}
install_backend_hooks_base() {
    append_block /jffs/scripts/dnsmasq.postconf '# BEGIN VPN DOMAIN DNSMASQ' '# END VPN DOMAIN DNSMASQ' 'CONFIG="$1"
VPN_CONF="/jffs/configs/vpn-domain-routing.conf"
STAMP="/tmp/vpn-domain-dns-config.hash"
if ! ipset list vpn_domain_v4 >/dev/null 2>&1; then
    ipset create vpn_domain_v4 hash:ip family inet timeout 3600 || exit 1
fi
if ! /jffs/scripts/vpn-domain-dnsmasq-generate.sh; then
    logger -t vpn-domain-refresh "generation failed; retaining previous include"
fi
if [ -s "$VPN_CONF" ]; then
    hash="$(md5sum "$VPN_CONF" | awk "{print \$1}")"
    previous="$(cat "$STAMP" 2>/dev/null)"
    if [ "$hash" != "$previous" ]; then
        ipset flush vpn_domain_v4 || exit 1
    fi
    grep -Fq "conf-file=$VPN_CONF" "$CONFIG" || printf "%s\n" "conf-file=$VPN_CONF" >> "$CONFIG"
    printf "%s\n" "$hash" > "$STAMP"
fi' || die 'Cannot update dnsmasq.postconf.'
    append_block /jffs/scripts/services-start '# BEGIN VPN DOMAIN BACKEND' '# END VPN DOMAIN BACKEND' '(
    sleep 10
    /jffs/scripts/vpn-domain-refresh.sh >/tmp/vpn-domain-boot-refresh.log 2>&1
) &' || die 'Cannot update backend startup hook.'
    append_block /jffs/scripts/service-event-end '# BEGIN VPN DOMAIN BACKEND' '# END VPN DOMAIN BACKEND' 'case "$*" in
    *vpnrouting*|*wgc*|*firewall*|*dnsfilter*|*dnsmasq*)
        (
            sleep 2
            /jffs/scripts/vpn-domain-refresh.sh
        ) &
        ;;
esac' || die 'Cannot update backend event hook.'
}
assert_free_priority() {
    if ip -4 rule show | awk 'index($1,"11000:")==1{found=1} END{exit !found}'; then
        die 'Policy priority 11000 is already occupied; refusing a fresh installation.'
    fi
    # A foreign MARK producer using this field must be reviewed first.
    if iptables -t mangle -S 2>/dev/null | grep -Eq -- '--(set-xmark|set-mark|set-return) (0x0*100(/0x0*ff00)?|256)( |$)'; then
        die 'An existing firewall rule uses mark 0x100; inspect it before installation.'
    fi
}
# Refuse unknown legacy hook ownership during migration. Ordinary install
# remains WebUI-only and never enters this check.
assert_managed_hooks() {
    for spec in 'dnsmasq.postconf|# BEGIN VPN DOMAIN DNSMASQ|# END VPN DOMAIN DNSMASQ' 'services-start|# BEGIN VPN DOMAIN BACKEND|# END VPN DOMAIN BACKEND' 'service-event-end|# BEGIN VPN DOMAIN BACKEND|# END VPN DOMAIN BACKEND'; do
        fname="${spec%%|*}"; rest="${spec#*|}"; begin="${rest%%|*}"; end="${rest#*|}"
        file="/jffs/scripts/$fname"
        [ -f "$file" ] || die "Backend hook missing: $file. Migration requires inspection, not automatic rewriting."
        validate_block "$file" "$begin" "$end"
        grep -Fxq "$begin" "$file" || die "Unmarked legacy integration in $file. WebUI repair is safe; automatic migration is refused."
        awk -v b="$begin" -v e="$end" '$0==b{inside=1;next} $0==e{inside=0;next} !inside{print}' "$file" > "$WORK/hook-check"
        if grep -Eq 'vpn-domain-(refresh|routing|dnsmasq-generate)\.sh|vpn-domain-routing\.conf|vpn_domain_v4' "$WORK/hook-check"; then
            die "Unmarked VPN Domains references in $file. Refusing migration/removal of unknown integration."
        fi
    done
}
assert_known_backend() {
    # For older installers, only migrate the exact embedded reference backend.
    if [ -f "$MANAGED" ] && grep -q 'VPNDOMAIN_ROUTING_V3' /jffs/scripts/vpn-domain-routing.sh; then return 0; fi
    for asset in vpn-domain-routing.sh vpn-domain-refresh.sh vpn-domain-dnsmasq-generate.sh; do
        expected="$(cat "$WORK/reference-$asset.md5")"
        actual="$(md5sum "/jffs/scripts/$asset" | awk '{print $1}')"
        [ "$actual" = "$expected" ] || die "Unknown legacy backend: $asset. Refusing to replace it automatically; ordinary install still repairs WebUI only."
    done
}
remove_webui_runtime() {
    exec 9>/tmp/addonwebui.lock
    /usr/bin/flock -x 9 || die 'Cannot lock shared WebUI menu.'
    if [ -f /tmp/menuTree.js ]; then
        awk '!/vpdomain-webui/' /tmp/menuTree.js > /tmp/menuTree.js.vpdomain.$$
        cat /tmp/menuTree.js.vpdomain.$$ > /tmp/menuTree.js
        rm -f /tmp/menuTree.js.vpdomain.$$
    fi
    for page in /www/user/user*.asp; do
        [ -f "$page" ] || continue
        if grep -q 'VPDOMAIN_WEBUI_V1' "$page"; then rm -f "$page"; fi
    done
    if [ -L /www/user/vpdomain ] && [ "$(readlink /www/user/vpdomain)" = "$WEB" ]; then rm -f /www/user/vpdomain; fi
    rm -rf "$WEB"
}
status_main() {
    echo '=== VPN Domains status ==='
    if [ -f "$MANAGED" ]; then echo "Mode: managed-v3 ($(cat "$MANAGED"))"; elif [ -f "$OLD_MANAGED" ]; then echo 'Mode: managed-v2'; else echo 'Mode: legacy / not installed'; fi
    [ ! -f "$DIR/.disabled" ] || echo 'Integration: disabled'
    [ ! -f "$DIR/.install-incomplete" ] || echo 'WARNING: incomplete installation marker exists'
    echo "WebUI page: $(cat "$DIR/page" 2>/dev/null || echo unavailable)"
    echo "Allowlist: $LIST"
    echo "WireGuard interface: $(get_setting WG_INTERFACE)"
    echo "WireGuard table: $(get_setting WG_TABLE)"
    for asset in vpn-domain-dnsmasq-generate.sh vpn-domain-routing.sh vpn-domain-refresh.sh; do
        if [ -x "/jffs/scripts/$asset" ]; then echo "OK: $asset"; else echo "MISSING: $asset"; fi
    done
    [ ! -x /jffs/scripts/vpn-domain-routing.sh ] || /jffs/scripts/vpn-domain-routing.sh status
}

emit_assets_base() {
    cat > "$WORK/VPNDomain.asp" <<'VPNDOMAIN_EMBEDDED_ASSET_0_END'
<!-- VPDOMAIN_WEBUI_V1 -->
<!DOCTYPE html>
<html><head>
<meta charset="utf-8"><meta http-equiv="Cache-Control" content="no-store">
<title>LAN - VPN Domains</title>
<link rel="stylesheet" href="/index_style.css"><link rel="stylesheet" href="/form_style.css">
<script src="/js/jquery.js"></script><script src="/state.js"></script>
<script src="/general.js"></script><script src="/popup.js"></script>
<script src="/help.js"></script><script src="/detect.js"></script>
<script id="addon-settings" type="application/json"><% get_custom_settings(); %></script>
<style>
#editor{width:96%;height:330px;font:14px monospace;background:#18232a;color:#eee;padding:10px;box-sizing:border-box;}
.vpd-button{margin:12px 8px 10px 0;padding:8px 16px;cursor:pointer;}
#message{white-space:pre-wrap;margin:12px 0;} .vpd-note{line-height:1.6;margin:12px 0;}
</style>
<script>
let revision='', busy=false;
const labels={ready:'Ready.',read:'Allowlist loaded from the router.',saved:'Allowlist saved; DNS configuration prepared.',conflict:'The allowlist changed after this page was loaded. Click Reload.',invalid:'Invalid allowlist. Use lowercase domains, one per line; comments start with #.',too_large:'The allowlist exceeds the 3072-byte limit.',bad_payload:'Invalid allowlist payload.',backend_busy:'The backend is busy. Please retry shortly.',apply_failed:'Apply failed. A rollback was attempted; check the router syslog.',not_available:'Entware or the VPN backend is unavailable.'};
function msg(t){document.getElementById('message').textContent=t;}
function buttons(on){document.querySelectorAll('.vpd-button').forEach(b=>b.disabled=!on);}
function decode64(s){return new TextDecoder().decode(Uint8Array.from(atob(s),c=>c.charCodeAt(0)));}
function encode64(bytes){return btoa(String.fromCharCode.apply(null,bytes));}
function requestId(){let a=new Uint32Array(2);crypto.getRandomValues(a);return Date.now().toString(16)+Array.from(a,x=>x.toString(16)).join('');}
async function getState(){const r=await fetch('/user/vpdomain/state.json?t='+Date.now(),{cache:'no-store',credentials:'same-origin'});if(!r.ok)throw Error('Failed to read state: HTTP '+r.status);return r.json();}
async function freshSettings(){const r=await fetch(location.pathname+'?settings='+Date.now(),{cache:'no-store',credentials:'same-origin'});if(!r.ok)throw Error('Failed to read WebUI settings.');const d=new DOMParser().parseFromString(await r.text(),'text/html');const e=d.getElementById('addon-settings');if(!e)throw Error('Your WebUI session may have expired. Sign in again.');return JSON.parse(e.textContent);}
async function command(action){
 if(busy)return;
 if(action==='save'&&!revision){msg('Click Reload before saving.');return;}
 let text=document.getElementById('editor').value.replace(/\r\n?/g,'\n');
 let bytes=new TextEncoder().encode(text);
 if(action==='save'&&bytes.length>3072){msg(labels.too_large);return;}
 busy=true;buttons(false);msg(action==='save'?'Saving and applying...':'Loading allowlist...');
 try{
  const settings=await freshSettings();
  ['_vpdomain_action','_vpdomain_request','_vpdomain_payload','_vpdomain_revision'].forEach(k=>delete settings[k]);
  const id=requestId();settings._vpdomain_action=action;settings._vpdomain_request=id;
  if(action==='save'){settings._vpdomain_payload=encode64(bytes);settings._vpdomain_revision=revision;}
  const serialized=JSON.stringify(settings);
  if(new TextEncoder().encode(serialized).length>7000)throw Error('Shared add-on settings are nearly full. Reduce the allowlist size.');
  const f=document.forms.form;f.current_page.value=location.pathname.substring(1);f.next_page.value=f.current_page.value;
  f.amng_custom.value=serialized;f.submit();
  let completed=false;
  for(let i=0;i<75;i++){
   await new Promise(r=>setTimeout(r,1000));
   let s;try{s=await getState();}catch(e){continue;}
   if(s.request!==id)continue;
   if(s.code===0){document.getElementById('editor').value=decode64(s.list_b64);revision=s.revision;}
   msg(labels[s.result]||s.result);completed=true;break;
  }
  if(!completed)throw Error('No operation confirmation received. Check syslog for vpdomain-webui.');
 }catch(e){msg(e.message);}finally{busy=false;buttons(true);}
}
function done_validating(){}
function initial(){
 const f=document.forms.form;
 f.current_page.value=location.pathname.substring(1);f.next_page.value=f.current_page.value;
 getState().then(s=>{document.getElementById('editor').value=decode64(s.list_b64);revision=s.revision;msg(labels[s.result]||'Ready.');}).catch(e=>msg(e.message));
 const moduleId='/require/modules/menuTree.js';
 const moduleMap={};moduleMap[moduleId]=moduleId+'?vpdomain_menu='+Date.now();
 requirejs.config({map:{'*':moduleMap}});
 require([moduleId],function(tree){
  const page=f.current_page.value;
  const found=tree.list.some(function(menu){return (menu.tab||[]).some(function(tab){return tab.url===page;});});
  if(!found){msg('This page is missing from the current router menu.');return;}
  Session.set('menuList.'+ui_lang,tree.list);
  Session.set('menuExclude',{menus:tree.exclude.menus(),tabs:tree.exclude.tabs()});show_menu();
 },function(error){console.error('VPN Domains menu load failed:',error);msg('Unable to load the router menu. Check the browser console.');});
}
</script></head>
<body class="bg" onload="initial()">
<div id="TopBanner"></div><div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" style="display:none"></iframe>
<form method="post" name="form" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value=""><input type="hidden" name="next_page" value="">
<input type="hidden" name="group_id" value=""><input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply"><input type="hidden" name="action_wait" value="0">
<input type="hidden" name="first_time" value=""><input type="hidden" name="action_script" value="restart_vpndomain">
<input type="hidden" name="preferred_lang" value="<% nvram_get("preferred_lang"); %>">
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>">
<input type="hidden" name="amng_custom" value="">
<table class="content" align="center" cellpadding="0" cellspacing="0"><tr>
<td width="17"></td><td valign="top" width="202"><div id="mainMenu"></div><div id="subMenu"></div></td>
<td valign="top"><div id="tabMenu" class="submenuBlock"></div>
<table width="760" class="FormTitle" cellpadding="12"><tr><td bgcolor="#4D595D">
<div class="formfonttitle">VPN Domains</div><div class="splitLine" style="margin:12px 0"></div>
<div class="vpd-note">One lowercase domain per line. example.com includes the domain and all its subdomains.<br>
Comments start with #. Do not use *. or URLs. Allowlist limit: 3072 bytes.<br>
Applies to all local networks. DNS filtering is not bypassed. IPv4 routing only; no VPN kill switch.</div>
<textarea id="editor" spellcheck="false" autocomplete="off"></textarea><br>
<div class="apply_gen">
<input class="button_gen vpd-button" type="button" value="Save and apply" onclick="command('save');">
<input class="button_gen vpd-button" type="button" value="Reload" onclick="command('read');">
</div><div id="message" role="status"></div>
</td></tr></table></td></tr></table></form><div id="footer"></div></body></html>
VPNDOMAIN_EMBEDDED_ASSET_0_END
    cat > "$WORK/lib.sh" <<'VPNDOMAIN_EMBEDDED_ASSET_1_END'
#!/bin/sh
DIR="/jffs/addons/vpn-domain"
WEB="/tmp/vpdomain-webui"
LIST="/jffs/configs/vpn-domain-allowlist.txt"
LC_ALL=C
export LC_ALL
. /usr/sbin/helper.sh
publish() {
    mkdir -p "$WEB" || return 1
    [ -r "$LIST" ] || return 1
    list64="$(/opt/bin/base64 "$LIST" | awk '{printf "%s", $0}')"
    revision="$(md5sum "$LIST" | awk '{print $1}')"
    result="$(cat "$WEB/result" 2>/dev/null)"
    request="$(cat "$WEB/request" 2>/dev/null)"
    code="$(cat "$WEB/code" 2>/dev/null)"
    case "$result" in ''|*[!a-z_]*) result=ready ;; esac
    case "$request" in *[!a-zA-Z0-9_-]*) request='' ;; esac
    case "$code" in 0|1) ;; *) code=0 ;; esac
    cat > "$WEB/state.json.tmp.$$" <<JSON
{"list_b64":"$list64","revision":"$revision","result":"$result","code":$code,"request":"$request","updated":$(date +%s)}
JSON
    chmod 644 "$WEB/state.json.tmp.$$" || return 1
    mv -f "$WEB/state.json.tmp.$$" "$WEB/state.json"
}
finish() {
    printf '%s\n' "$1" > "$WEB/result"
    printf '%s\n' "$2" > "$WEB/code"
    printf '%s\n' "$REQ" > "$WEB/request"
    publish
    logger -t vpdomain-webui "result=$1 request=$REQ"
}
clear_request() {
    sed -i '/^_vpdomain_action /d; /^_vpdomain_request /d; /^_vpdomain_payload /d; /^_vpdomain_revision /d' /jffs/addons/custom_settings.txt
}
VPNDOMAIN_EMBEDDED_ASSET_1_END
    cat > "$WORK/mount.sh" <<'VPNDOMAIN_EMBEDDED_ASSET_2_END'
#!/bin/sh
. /jffs/addons/vpn-domain/lib.sh
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -x /opt/bin/base64 ] && [ -f /www/require/modules/menuTree.js ] && break
    sleep 5
done
[ -x /opt/bin/base64 ] || { logger -t vpdomain-webui "Entware not ready"; exit 1; }
mkdir -p /www/user "$WEB" || exit 1
exec 9>/tmp/addonwebui.lock
/usr/bin/flock -x 9 || exit 1
TREE="/tmp/menuTree.js"
[ -f "$TREE" ] || cp /www/require/modules/menuTree.js "$TREE" || exit 1
if grep -q 'Advanced_VLAN_Switch_Content.asp' "$TREE"; then
    ANCHOR="Advanced_VLAN_Switch_Content.asp"
elif grep -q 'Advanced_SwitchCtrl_Content.asp' "$TREE"; then
    ANCHOR="Advanced_SwitchCtrl_Content.asp"
else
    logger -t vpdomain-webui "LAN menu anchor not found; no menu changes made"
    exit 1
fi
PAGE=""
for f in /www/user/user*.asp; do
    if [ -f "$f" ] && grep -q 'VPDOMAIN_WEBUI_V1' "$f"; then PAGE="${f##*/}"; break; fi
done
if [ -z "$PAGE" ]; then
    am_get_webui_page "$DIR/VPNDomain.asp"
    PAGE="$am_webui_page"
fi
case "$PAGE" in user[0-9].asp|user[0-9][0-9].asp) ;; *) exit 1 ;; esac
if [ -e /www/user/vpdomain ] && [ ! -L /www/user/vpdomain ]; then
    logger -t vpdomain-webui "Resource path already occupied"; exit 1
fi
if [ -L /www/user/vpdomain ] && [ "$(readlink /www/user/vpdomain)" != "$WEB" ]; then
    logger -t vpdomain-webui "Resource symlink belongs to another module"; exit 1
fi
ln -snf "$WEB" /www/user/vpdomain || exit 1
if [ -e "/www/user/$PAGE" ] && ! grep -q 'VPDOMAIN_WEBUI_V1' "/www/user/$PAGE"; then
    logger -t vpdomain-webui "Refusing to overwrite another WebUI page: $PAGE"
    exit 1
fi
cp "$DIR/VPNDomain.asp" "/www/user/$PAGE" || exit 1
chmod 644 "/www/user/$PAGE"
printf '%s\n' "$PAGE" > "$DIR/page"
awk -v anchor="$ANCHOR" -v page="$PAGE" '
 /vpdomain-webui/ {next}
 {print}
 !added && index($0,anchor) {
   print "{url: \"" page "\", tabName: \"VPN Domains\"}, // vpdomain-webui"
   added=1
 }
' "$TREE" > "$TREE.vpdomain.$$" || exit 1
cat "$TREE.vpdomain.$$" > "$TREE" || exit 1
rm -f "$TREE.vpdomain.$$"
if ! grep -Fq ' /www/require/modules/menuTree.js ' /proc/mounts; then
    mount -o bind "$TREE" /www/require/modules/menuTree.js || exit 1
fi
publish || exit 1
logger -t vpdomain-webui "mounted page=$PAGE"
echo "LAN -> VPN Domains ($PAGE)"
VPNDOMAIN_EMBEDDED_ASSET_2_END
    cat > "$WORK/webui-handler.sh" <<'VPNDOMAIN_EMBEDDED_ASSET_3_END'
#!/bin/sh
. /jffs/addons/vpn-domain/lib.sh
mkdir -p "$WEB" || exit 1
exec 8>/tmp/vpdomain-webui-handler.lock
/usr/bin/flock -x 8 || exit 1
ACTION="$(am_settings_get _vpdomain_action)"
REQ="$(am_settings_get _vpdomain_request)"
PAYLOAD="$(am_settings_get _vpdomain_payload)"
REV="$(am_settings_get _vpdomain_revision)"
clear_request
case "$REQ" in ''|*[!a-zA-Z0-9_-]*) exit 1 ;; esac
[ "${#REQ}" -le 80 ] || exit 1
case "$ACTION" in read) finish read 0; exit 0 ;; save) ;; *) finish bad_payload 1; exit 1 ;; esac
[ -x /opt/bin/base64 ] && [ -x /jffs/scripts/vpn-domain-refresh.sh ] || { finish not_available 1; exit 1; }
[ "${#PAYLOAD}" -le 4096 ] || { finish too_large 1; exit 1; }
[ "$REV" = "$(md5sum "$LIST" | awk '{print $1}')" ] || { finish conflict 1; exit 1; }
RAW="$DIR/list.raw.$$"
CAND="$DIR/list.candidate.$$"
TEST="$DIR/list.test.$$"
trap 'rm -f "$RAW" "$CAND" "$TEST"' 0
trap 'exit 1' 1 2 15
umask 077
printf '%s' "$PAYLOAD" | /opt/bin/base64 -d > "$RAW" 2>/dev/null || { finish bad_payload 1; exit 1; }
[ "$(wc -c < "$RAW")" -le 3072 ] || { finish too_large 1; exit 1; }
awk '
 {
   sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
   if ($0=="" || substr($0,1,1)=="#") {print; next}
   if (length($0)>253 || $0 !~ /^[a-z0-9.-]+$/ || index($0,".")==0) {bad=1; next}
   n=split($0,a,".")
   for(i=1;i<=n;i++) {
     if(length(a[i])<1 || length(a[i])>63 || a[i] !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) bad=1
   }
   print
 }
 END {if(bad)exit 1}
' "$RAW" > "$CAND" || { finish invalid 1; exit 1; }
awk '$0!="" && substr($0,1,1)!="#" {print "ipset=/" $0 "/vpn_domain_v4"}' "$CAND" > "$TEST"
dnsmasq --test --conf-file="$TEST" >/tmp/vpdomain-webui-test.log 2>&1 || { finish invalid 1; exit 1; }
waited=0
while [ -d /tmp/vpn-domain-refresh.lock ] && [ "$waited" -lt 15 ]; do sleep 1; waited=$((waited+1)); done
[ ! -d /tmp/vpn-domain-refresh.lock ] || { finish backend_busy 1; exit 1; }
[ "$REV" = "$(md5sum "$LIST" | awk '{print $1}')" ] || { finish conflict 1; exit 1; }
cp -p "$LIST" "$DIR/allowlist.previous" || { finish apply_failed 1; exit 1; }
chmod 644 "$CAND"
mv -f "$CAND" "$LIST" || { finish apply_failed 1; exit 1; }
ok=0
if /jffs/scripts/vpn-domain-refresh.sh >/tmp/vpdomain-webui-apply.log 2>&1; then
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        expected="$(md5sum /jffs/configs/vpn-domain-routing.conf | awk '{print $1}')"
        loaded="$(cat /tmp/vpn-domain-dns-config.hash 2>/dev/null)"
        if [ -n "$expected" ] && [ "$expected" = "$loaded" ] && [ -n "$(pidof dnsmasq)" ]; then ok=1; break; fi
        sleep 1
    done
fi
if [ "$ok" = 1 ]; then finish saved 0; else
    cp -p "$DIR/allowlist.previous" "$LIST"
    /jffs/scripts/vpn-domain-refresh.sh >>/tmp/vpdomain-webui-apply.log 2>&1
    finish apply_failed 1; exit 1
fi
VPNDOMAIN_EMBEDDED_ASSET_3_END
    cat > "$WORK/vpn-domain-dnsmasq-generate.sh" <<'VPNDOMAIN_EMBEDDED_ASSET_4_END'
#!/bin/sh
ALLOWLIST="/jffs/configs/vpn-domain-allowlist.txt"
OUT="/jffs/configs/vpn-domain-routing.conf"
TMP="${OUT}.tmp.$$"
TAG="vpn-domain-refresh"
umask 022
[ -r "$ALLOWLIST" ] || { logger -t "$TAG" "ERROR: allowlist unreadable"; exit 1; }
trap 'rm -f "$TMP"' 0
trap 'exit 1' 1 2 15
awk '
 BEGIN {print "# Generated by VPN Domains; do not edit."}
 {
   sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
   if ($0=="" || substr($0,1,1)=="#") next
   if (length($0)>253 || $0 !~ /^[a-z0-9.-]+$/ || index($0,".")==0) {bad=1; next}
   n=split($0,a,".")
   for(i=1;i<=n;i++) if(length(a[i])<1 || length(a[i])>63 || a[i] !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) bad=1
   print "ipset=/" $0 "/vpn_domain_v4"
 }
 END {if(bad)exit 1}
' "$ALLOWLIST" > "$TMP" || { logger -t "$TAG" "ERROR: invalid allowlist"; exit 1; }
dnsmasq --test --conf-file="$TMP" >/tmp/vpn-domain-config-test.log 2>&1 || {
    logger -t "$TAG" "ERROR: syntax test failed; see /tmp/vpn-domain-config-test.log"; exit 1;
}
chmod 644 "$TMP" || exit 1
if [ -f "$OUT" ] && [ "$(md5sum "$TMP" | awk '{print $1}')" = "$(md5sum "$OUT" | awk '{print $1}')" ]; then exit 0; fi
mv -f "$TMP" "$OUT"
VPNDOMAIN_EMBEDDED_ASSET_4_END
    cat > "$WORK/vpn-domain-refresh.sh" <<'VPNDOMAIN_EMBEDDED_ASSET_5_END'
#!/bin/sh
LOCK="/tmp/vpn-domain-refresh.lock"
CONF="/jffs/configs/vpn-domain-routing.conf"
STAMP="/tmp/vpn-domain-dns-config.hash"
TAG="vpn-domain-refresh"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' 0
trap 'exit 1' 1 2 15
/jffs/scripts/vpn-domain-dnsmasq-generate.sh || exit 1
hash="$(md5sum "$CONF" | awk '{print $1}')"
previous="$(cat "$STAMP" 2>/dev/null)"
if [ "$hash" != "$previous" ]; then
    logger -t "$TAG" "allowlist changed or not yet loaded; requesting DNS restart"
    service restart_dnsmasq || exit 1
else
    logger -t "$TAG" "allowlist unchanged; DNS restart skipped"
fi
/jffs/scripts/vpn-domain-routing.sh apply
VPNDOMAIN_EMBEDDED_ASSET_5_END
    cat > "$WORK/vpn-domain-routing.sh" <<'VPNDOMAIN_EMBEDDED_ASSET_6_END'
#!/bin/sh
# VPNDOMAIN_ROUTING_V3 -- generated by the standalone installer.
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/opt/sbin:/opt/bin"
export PATH
SET="vpn_domain_v4"
CFG="/jffs/configs/vpn-domain-settings.conf"
TAG="vpn-domain-routing"
MAX_HANDSHAKE_AGE=180
MARK="0x100"
MASK="0xff00"
PREF="11000"
IFACE=""
TABLE=""
load_config() {
    [ -r "$CFG" ] || return 1
    IFACE="$(sed -n 's/^WG_INTERFACE=//p' "$CFG")"
    TABLE="$(sed -n 's/^WG_TABLE=//p' "$CFG")"
    case "$IFACE" in wgc[1-9]|wgc[1-9][0-9]) ;; *) return 1 ;; esac
    case "$TABLE" in ''|*[!0-9]*) return 1 ;; esac
    [ "$TABLE" -gt 0 ] && [ "$TABLE" -lt 253 ]
}
ensure_set() {
    ipset list "$SET" >/dev/null 2>&1 || ipset create "$SET" hash:ip family inet timeout 3600
}
remove_rules() {
    while iptables -t mangle -D PREROUTING -m set --match-set "$SET" dst -j MARK --set-xmark "$MARK/$MASK" 2>/dev/null; do :; done
    while ip rule del pref "$PREF" fwmark "$MARK/$MASK" lookup "$TABLE" 2>/dev/null; do :; done
}
handshake_status() {
    now="$(date +%s)"
    wg show "$IFACE" latest-handshakes 2>/dev/null | awk -v now="$now" '
      $2 ~ /^[0-9]+$/ && $2>0 && $2<=now {age=now-$2; if(!seen || age<best)best=age; seen=1}
      END {if(seen)print best; else print "unavailable"}'
}
tunnel_ready() {
    ip link show dev "$IFACE" >/dev/null 2>&1 || return 1
    ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet ' || return 1
    routes="$(ip -4 route show table "$TABLE" 2>/dev/null)"
    printf '%s\n' "$routes" | awk -v iface="$IFACE" '
      {correct=0; for(i=1;i<NF;i++)if($i=="dev" && $(i+1)==iface)correct=1}
      correct && $1=="default" {full=1}
      correct && $1=="0.0.0.0/1" {lower=1}
      correct && $1=="128.0.0.0/1" {upper=1}
      END {exit !(full || (lower && upper))}' || return 1
    age="$(handshake_status)"
    case "$age" in ''|*[!0-9]*) return 1 ;; esac
    [ "$age" -le "$MAX_HANDSHAKE_AGE" ]
}
apply_rules() {
    # Do not take over a foreign policy rule at our reserved priority.
    ip -4 rule show | awk -v p="$PREF:" 'index($1,p)==1{found=1} END{exit !found}' && {
        logger -t "$TAG" "ERROR: policy priority $PREF is occupied"; return 1;
    }
    ip rule add pref "$PREF" fwmark "$MARK/$MASK" lookup "$TABLE" || return 1
    if ! iptables -t mangle -I PREROUTING 1 -m set --match-set "$SET" dst -j MARK --set-xmark "$MARK/$MASK"; then
        ip rule del pref "$PREF" fwmark "$MARK/$MASK" lookup "$TABLE" 2>/dev/null
        return 1
    fi
}
load_config || { logger -t "$TAG" "ERROR: missing or invalid WireGuard settings"; exit 1; }
# Serialize event-driven refreshes, reconfiguration and removal.
exec 7>/tmp/vpn-domain-routing.lock
/usr/bin/flock -x 7 || exit 1
case "${1:-status}" in
    apply)
        ensure_set || exit 1
        remove_rules
        if tunnel_ready; then
            apply_rules || exit 1
            logger -t "$TAG" "enabled: set=$SET interface=$IFACE table=$TABLE handshake=$(handshake_status)s"
        else
            logger -t "$TAG" "disabled: interface=$IFACE handshake=$(handshake_status); normal routing remains active"
        fi
        ;;
    remove) remove_rules; logger -t "$TAG" "removed domain routing rules" ;;
    status)
        echo "WireGuard: $IFACE; table: $TABLE; handshake age: $(handshake_status)"
        if tunnel_ready; then echo 'Tunnel: ready'; else echo 'Tunnel: not ready'; fi
        echo; echo 'IP set:'; ipset list "$SET" 2>/dev/null || true
        echo; echo 'Mangle rules:'
        iptables -t mangle -L PREROUTING -n -v --line-numbers | grep -E "$SET|Chain" || true
        echo; echo 'Policy rules:'; ip -4 rule show | awk -v p="$PREF:" 'index($1,p)==1'
        ;;
    *) echo "Usage: $0 {apply|remove|status}" >&2; exit 1 ;;
esac
VPNDOMAIN_EMBEDDED_ASSET_6_END
    cat > "$WORK/vpn-domain-allowlist.default.txt" <<'VPNDOMAIN_EMBEDDED_ASSET_7_END'
# VPN destination-domain allowlist.
# One base domain per line; subdomains are included automatically.

VPNDOMAIN_EMBEDDED_ASSET_7_END
    printf '%s\n' '8cf5d581181b2a080fa66330cdad8068' > "$WORK/reference-vpn-domain-routing.sh.md5"
    printf '%s\n' '46354819b8c07730ca88e93342c67c02' > "$WORK/reference-vpn-domain-refresh.sh.md5"
    printf '%s\n' '955641680b4eb456f8fcf5f40b9479ad' > "$WORK/reference-vpn-domain-dnsmasq-generate.sh.md5"
}

# Managed legacy compatibility and transactions (3.0.1).
backup_file() {
    [ -e "$1" ] || return 0
    backup_dest="$BACKUP$1"
    [ ! -e "$backup_dest" ] || return 0
    mkdir -p "${backup_dest%/*}" || die 'Cannot create backup directory.'
    cp -p "$1" "$backup_dest" || die "Cannot back up $1"
}
cleanup() {
    saved_exit=$?
    trap - 0
    if [ "$TX_ACTIVE" = 1 ]; then rollback_change; fi
    if [ "$REFRESH_LOCKED" = 1 ]; then rmdir /tmp/vpn-domain-refresh.lock 2>/dev/null || true; fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    [ "$LOCKED" = 0 ] || rmdir /tmp/vpn-domain-install.lock 2>/dev/null || true
    exit "$saved_exit"
}
preflight_backend() {
    ip -4 rule show >/dev/null 2>&1 || die 'Cannot execute: ip -4 rule show'
    iptables -t mangle -S >/dev/null 2>&1 || die 'Cannot read the iptables mangle table.'
    ipset list >/dev/null 2>&1 || die 'Cannot execute: ipset list'
    wg show interfaces >/dev/null 2>&1 || die 'Cannot execute: wg show interfaces'
    dnsmasq --version >/dev/null 2>&1 || die 'Cannot execute: dnsmasq --version'
    md5sum /dev/null >/dev/null 2>&1 || die 'Cannot execute: md5sum'
    awk 'BEGIN {exit 0}' </dev/null >/dev/null 2>&1 || die 'Cannot execute: awk'
    [ -x /usr/bin/flock ] || die '/usr/bin/flock is missing.'
    cru l >/dev/null 2>&1 || die 'Cannot inspect cron using cru l.'
}
partial_exists() {
    for partial_file in /jffs/scripts/vpn-domain-dnsmasq-generate.sh /jffs/scripts/vpn-domain-routing.sh /jffs/scripts/vpn-domain-refresh.sh "$CONF" "$CFG" "$MANAGED" "$OLD_MANAGED" "$DIR/.install-incomplete" "$DIR/.disabled"; do
        [ ! -e "$partial_file" ] || return 0
    done
    for partial_file in /jffs/scripts/dnsmasq.postconf /jffs/scripts/services-start /jffs/scripts/service-event-end /jffs/scripts/nat-start; do
        [ ! -f "$partial_file" ] || ! grep -Eq 'VPN DOMAIN BACKEND|VPN DOMAIN DNSMASQ|vpn-domain-(refresh|routing|dnsmasq-generate)\.sh|VPNDomainRoutingHealth' "$partial_file" || return 0
    done
    return 1
}
remove_exact() {
    awk -v pattern="$2" '
      BEGIN {while ((getline x < pattern)>0)p[++n]=x;close(pattern);if(!n)exit 2}
      {a[NR]=$0}
      END {
        if(!n)exit 2
        for(i=1;i<=NR;) {
          matchblock=(i+n-1<=NR)
          for(j=1;matchblock && j<=n;j++)if(a[i+j-1]!=p[j])matchblock=0
          if(matchblock){matches++;i+=n}else{print a[i];i++}
        }
        if(matches>1)exit 3
      }' "$1" > "$1.next" || die "Ambiguous legacy block in $1"
    mv "$1.next" "$1" || die 'Cannot stage legacy cleanup.'
}
hook_names='services-start service-event service-event-end dnsmasq.postconf nat-start'
prepare_hook_plan() {
    plan_mode="$1"
    mkdir -p "$WORK/hook-plan" || die 'Cannot stage hook plan.'
    : > "$WORK/hook-fingerprints"
    for hp_name in $hook_names; do
        hp_live="/jffs/scripts/$hp_name"
        hp_copy="$WORK/hook-plan/$hp_name"
        [ ! -L "$hp_live" ] || die "Refusing to rewrite a symlinked hook: $hp_live"
        if [ -f "$hp_live" ]; then
            md5sum "$hp_live" >> "$WORK/hook-fingerprints" || die 'Cannot fingerprint hook.'
            cp -p "$hp_live" "$hp_copy" || die 'Cannot stage hook.'
        else
            printf 'MISSING %s\n' "$hp_live" >> "$WORK/hook-fingerprints"
            printf '%s\n' '#!/bin/sh' > "$hp_copy"
        fi
        strip_block "$hp_copy" '# BEGIN VPN DOMAIN BACKEND' '# END VPN DOMAIN BACKEND' || die 'Cannot plan backend removal.'
        strip_block "$hp_copy" '# BEGIN VPN DOMAIN DNSMASQ' '# END VPN DOMAIN DNSMASQ' || die 'Cannot plan DNS removal.'
        strip_block "$hp_copy" '# BEGIN VPN DOMAIN HEALTH' '# END VPN DOMAIN HEALTH' || die 'Cannot plan health removal.'
        if [ "$plan_mode" = uninstall ]; then
            strip_block "$hp_copy" '# BEGIN VPDOMAIN WEBUI' '# END VPDOMAIN WEBUI' || die 'Cannot plan WebUI removal.'
        fi
        case "$hp_name" in
            service-event-end) remove_exact "$hp_copy" "$WORK/legacy-event" ;;
            dnsmasq.postconf) remove_exact "$hp_copy" "$WORK/legacy-dns" ;;
            nat-start)
                remove_exact "$hp_copy" "$WORK/legacy-cron"
                remove_exact "$hp_copy" "$WORK/legacy-delay"
                ;;
        esac
        if grep -Eq 'vpn-domain-(refresh|routing|dnsmasq-generate)\.sh|vpn-domain-routing\.conf|vpn_domain_v4|VPNDomainRoutingHealth' "$hp_copy"; then
            die "Unrecognized VPN Domains integration remains in $hp_live. No hooks were changed."
        fi
        sh -n "$hp_copy" || die "Invalid planned hook: $hp_name"
    done
    for hp_other in /jffs/scripts/*; do
        [ -f "$hp_other" ] || continue
        case "${hp_other##*/}" in
            services-start|service-event|service-event-end|dnsmasq.postconf|nat-start|vpn-domain-routing.sh|vpn-domain-refresh.sh|vpn-domain-dnsmasq-generate.sh) continue ;;
        esac
        case "${hp_other##*/}" in
            *-start|*-end|*.postconf|wan-event)
                if grep -Eq 'vpn-domain-(refresh|routing|dnsmasq-generate)\.sh|VPNDomainRoutingHealth' "$hp_other"; then
                    die "Additional legacy integration in $hp_other requires inspection."
                fi
                ;;
        esac
    done
}
verify_hook_plan() {
    : > "$WORK/hook-fingerprints-now"
    for hp_name in $hook_names; do
        hp_live="/jffs/scripts/$hp_name"
        if [ -f "$hp_live" ]; then md5sum "$hp_live" >> "$WORK/hook-fingerprints-now"; else printf 'MISSING %s\n' "$hp_live" >> "$WORK/hook-fingerprints-now"; fi
    done
    before_hash="$(md5sum "$WORK/hook-fingerprints" | awk '{print $1}')"
    now_hash="$(md5sum "$WORK/hook-fingerprints-now" | awk '{print $1}')"
    [ "$before_hash" = "$now_hash" ] || die 'A shared hook changed while waiting. Retry; no hooks were written.'
}
commit_hook_plan() {
    verify_hook_plan
    for hp_name in $hook_names; do
        hp_live="/jffs/scripts/$hp_name"
        backup_file "$hp_live"
        cat "$WORK/hook-plan/$hp_name" > "$hp_live" || die "Cannot write $hp_live"
        chmod 755 "$hp_live" || die "Cannot chmod $hp_live"
    done
}
health_remove() { cru d VPNDomainRoutingHealth >/dev/null 2>&1; }
health_enable() { cru a VPNDomainRoutingHealth '* * * * * /jffs/scripts/vpn-domain-routing.sh apply'; }
begin_change() {
    exec 6>/tmp/vpdomain-webui-handler.lock
    /usr/bin/flock -x 6 || die 'Cannot lock WebUI handler.'
    mkdir /tmp/vpn-domain-refresh.lock 2>/dev/null || die 'Backend refresh is busy; retry shortly.'
    REFRESH_LOCKED=1
    mkdir -p "$DIR" /jffs/scripts /jffs/configs || die 'Cannot create addon directories.'
    : > "$WORK/tx-files"
    for tx_path in "$LIST" "$CONF" "$CFG" "$MANAGED" "$OLD_MANAGED" "$DIR/.disabled" "$DIR/.install-incomplete" "$DIR/VPNDomain.asp" "$DIR/mount.sh" "$DIR/webui-handler.sh" "$DIR/lib.sh" "$DIR/page" /tmp/vpn-domain-dns-config.hash /jffs/scripts/vpn-domain-routing.sh /jffs/scripts/vpn-domain-refresh.sh /jffs/scripts/vpn-domain-dnsmasq-generate.sh; do
        printf '%s\n' "$tx_path" >> "$WORK/tx-files"
    done
    for tx_name in $hook_names; do printf '/jffs/scripts/%s\n' "$tx_name" >> "$WORK/tx-files"; done
    while IFS= read -r tx_path; do
        if [ -e "$tx_path" ]; then backup_file "$tx_path"; else
            mkdir -p "$BACKUP/.absent${tx_path%/*}" || die 'Cannot record absent file.'
            : > "$BACKUP/.absent$tx_path" || die 'Cannot record absent file.'
        fi
    done < "$WORK/tx-files"
    cru l > "$BACKUP/cron.before.txt" 2>/dev/null || die 'Cannot inspect cron.'
    if grep -q VPNDomainRoutingHealth "$BACKUP/cron.before.txt"; then HEALTH_WAS=1; else HEALTH_WAS=0; fi
    TX_ACTIVE=1
    health_remove || die 'Cannot remove VPN Domains health cron job.'
}
rollback_change() {
    TX_ACTIVE=0
    logger -t vpn-domain-install "Change failed; attempting rollback from $BACKUP"
    if [ -x /jffs/scripts/vpn-domain-routing.sh ]; then /jffs/scripts/vpn-domain-routing.sh remove >/dev/null 2>&1 || true; fi
    while IFS= read -r tx_path; do
        if [ -f "$BACKUP/.absent$tx_path" ]; then rm -f "$tx_path"; elif [ -f "$BACKUP$tx_path" ]; then
            cp -p "$BACKUP$tx_path" "$tx_path" || logger -t vpn-domain-install "ROLLBACK FAILED: $tx_path"
        fi
    done < "$WORK/tx-files"
    health_remove || true
    if [ "$HEALTH_WAS" = 1 ]; then health_enable || true; fi
    if [ "$DNS_TOUCHED" = 1 ]; then service restart_dnsmasq >/dev/null 2>&1 || true; fi
    if [ -x /jffs/scripts/vpn-domain-routing.sh ] && [ ! -f "$DIR/.disabled" ]; then /jffs/scripts/vpn-domain-routing.sh apply >/dev/null 2>&1 || true; fi
    printf 'Rollback attempted. Inspect router state. Backup: %s\n' "$BACKUP"
}
finish_change() {
    TX_ACTIVE=0
    if [ "$REFRESH_LOCKED" = 1 ]; then rmdir /tmp/vpn-domain-refresh.lock 2>/dev/null || true; REFRESH_LOCKED=0; fi
}
install_backend_hooks() {
    install_backend_hooks_base
    append_block /jffs/scripts/nat-start '# BEGIN VPN DOMAIN HEALTH' '# END VPN DOMAIN HEALTH' 'cru a VPNDomainRoutingHealth "* * * * * /jffs/scripts/vpn-domain-routing.sh apply"' || die 'Cannot install health startup hook.'
}
install_main() {
    preflight_webui
    if [ -f "$DIR/.disabled" ]; then die 'Integration is disabled. Use configure-vpn to explicitly re-enable it.'; fi
    if backend_exists; then
        log 'Existing backend detected. Updating only WebUI and its two marked hooks.'
        install_webui
        log "WebUI restored. Backend, allowlist, DNS config and VPN binding preserved. Backup: $BACKUP"
        return
    fi
    partial_exists && die 'Partial installation detected. No backend files were replaced.'
    preflight_backend
    assert_free_priority
    prepare_hook_plan backend
    select_wireguard
    confirm "Install VPN Domains for ALL local networks via $WG_INTERFACE (table $WG_TABLE)? DNS filters will not be changed."
    candidate_ready "$WG_INTERFACE" "$WG_TABLE" || die 'Selected tunnel is no longer ready; nothing installed.'
    verify_hook_plan
    begin_change
    printf '%s\n' "$VERSION" > "$DIR/.install-incomplete" || die 'Cannot create installation marker.'
    write_settings
    install_backend_files
    if [ ! -f "$LIST" ]; then write_asset vpn-domain-allowlist.default.txt "$LIST" 644; fi
    /jffs/scripts/vpn-domain-dnsmasq-generate.sh || die 'Allowlist validation failed.'
    commit_hook_plan
    install_backend_hooks
    DNS_TOUCHED=1
    service restart_dnsmasq || die 'Initial DNS restart failed.'
    /jffs/scripts/vpn-domain-routing.sh apply || die 'Initial routing apply failed.'
    install_webui
    health_enable || die 'Cannot enable VPN Domains health cron.'
    printf '%s\n' "$VERSION" > "$MANAGED" || die 'Cannot write management marker.'
    rm -f "$DIR/.install-incomplete" "$DIR/.disabled"
    finish_change
    log "Installation completed: $WG_INTERFACE (table $WG_TABLE), all local networks. Backup: $BACKUP"
    echo 'Open the router WebUI: LAN -> VPN Domains. Your page slot is shown above.'
}
configure_vpn() {
    backend_exists || die 'A complete backend is required. Use install for a fresh installation.'
    preflight_backend
    preflight_webui
    select_wireguard
    old_iface="$(get_setting WG_INTERFACE)"; old_table="$(get_setting WG_TABLE)"
    if [ -f "$MANAGED" ] && [ ! -f "$DIR/.disabled" ] && [ "$old_iface" = "$WG_INTERFACE" ] && [ "$old_table" = "$WG_TABLE" ]; then
        log 'Selected binding is unchanged. No files or routing rules modified.'; return
    fi
    assert_known_backend
    prepare_hook_plan backend
    confirm "Configure/migrate/re-enable VPN Domains via $WG_INTERFACE (table $WG_TABLE)? Backend and VPN Domains hook blocks will change; the allowlist and foreign integrations will be preserved."
    candidate_ready "$WG_INTERFACE" "$WG_TABLE" || die 'Selected tunnel is no longer ready; no changes applied.'
    verify_hook_plan
    begin_change
    /jffs/scripts/vpn-domain-routing.sh remove || die 'Cannot remove previous domain routing.'
    write_settings
    install_backend_files
    commit_hook_plan
    install_backend_hooks
    /jffs/scripts/vpn-domain-dnsmasq-generate.sh || die 'DNS include generation failed.'
    DNS_TOUCHED=1
    service restart_dnsmasq || die 'DNS restart failed.'
    /jffs/scripts/vpn-domain-routing.sh apply || die 'New domain routing failed.'
    install_webui
    health_enable || die 'Cannot enable health cron.'
    printf '%s\n' "$VERSION" > "$MANAGED" || die 'Cannot write management marker.'
    rm -f "$DIR/.disabled" "$DIR/.install-incomplete"
    finish_change
    log "WireGuard configured: $WG_INTERFACE, table $WG_TABLE. Backup: $BACKUP"
}
uninstall_main() {
    if [ -f "$DIR/.disabled" ]; then log 'Integration already disabled; preserved files were not removed.'; return; fi
    backend_exists || die 'Complete backend required for safe removal; partial installation needs inspection.'
    preflight_backend
    assert_known_backend
    prepare_hook_plan uninstall
    if [ "${1:-}" != '--confirmed' ]; then confirm 'Disable VPN Domains, remove its recognized hook blocks and health cron? Allowlist and addon/backend files will be preserved.'; fi
    verify_hook_plan
    begin_change
    commit_hook_plan
    /jffs/scripts/vpn-domain-routing.sh remove || die 'Cannot remove domain routing rules.'
    DNS_TOUCHED=1
    service restart_dnsmasq || die 'DNS restart failed.'
    printf '%s\n' "$VERSION" > "$DIR/.disabled" || die 'Cannot mark disabled integration.'
    remove_webui_runtime
    finish_change
    log "VPN Domains disabled. Its health cron and recognized hook blocks removed. Allowlist and files preserved. Backup: $BACKUP"
}
purge_main() {
    [ "${2:-}" = '--yes' ] || die 'Destructive command: sh install.sh purge --yes'
    confirm 'Permanently remove VPN Domains integration, addon directory and allowlist? External backups will be retained.'
    uninstall_main --confirmed
    for purge_file in "$LIST" "$CONF" "$CFG" /jffs/scripts/vpn-domain-routing.sh /jffs/scripts/vpn-domain-refresh.sh /jffs/scripts/vpn-domain-dnsmasq-generate.sh; do backup_file "$purge_file"; done
    mkdir -p "$BACKUP/jffs/addons" || die 'Cannot create purge backup.'
    if [ -d "$DIR" ] && [ ! -e "$BACKUP/jffs/addons/vpn-domain-full" ]; then cp -pR "$DIR" "$BACKUP/jffs/addons/vpn-domain-full" || die 'Cannot back up addon directory.'; fi
    rm -f /jffs/scripts/vpn-domain-dnsmasq-generate.sh /jffs/scripts/vpn-domain-routing.sh /jffs/scripts/vpn-domain-refresh.sh "$LIST" "$CONF" "$CFG" /tmp/vpn-domain-dns-config.hash
    rm -rf "$DIR"
    log "VPN Domains purged. Backups retained: $BACKUP"
}
check_main() {
    preflight_backend
    preflight_webui
    if backend_exists; then assert_known_backend; prepare_hook_plan uninstall
        log 'CHECK OK: backend recognized; hook cleanup preserves foreign blocks.'
    elif partial_exists; then die 'Partial installation detected. No configuration changed.'
    else log 'CHECK OK: fresh installation candidate.'; fi
    log 'No backend, allowlist, hook, cron or routing changes were applied.'
}
test_menu_main() {
    preflight_backend
    select_wireguard
    log "MENU TEST ONLY: $WG_INTERFACE, table $WG_TABLE. No configuration or routing changes applied."
}
emit_assets() {
    emit_assets_base
    cat > "$WORK/legacy-event" <<'VPNDOMAIN_LEGACY_EVENT_END'
case "$*" in
    *vpnrouting*|*wgc*|*firewall*|*dnsfilter*)
        (
            sleep 2
            /jffs/scripts/vpn-domain-refresh.sh
        ) &
        ;;
esac
VPNDOMAIN_LEGACY_EVENT_END
    cat > "$WORK/legacy-dns" <<'VPNDOMAIN_LEGACY_DNS_END'
CONFIG="$1"
VPN_CONF="/jffs/configs/vpn-domain-routing.conf"
STAMP="/tmp/vpn-domain-dns-config.hash"

if ! ipset list vpn_domain_v4 >/dev/null 2>&1; then
    ipset create vpn_domain_v4 hash:ip family inet timeout 3600 || exit 1
fi

if ! /jffs/scripts/vpn-domain-dnsmasq-generate.sh; then
    logger -t vpn-domain-refresh "generation failed; retaining previous include"
fi

if [ -s "$VPN_CONF" ]; then
    hash="$(md5sum "$VPN_CONF" | awk '{print $1}')"
    previous="$(cat "$STAMP" 2>/dev/null)"

    if [ "$hash" != "$previous" ]; then
        ipset flush vpn_domain_v4 || exit 1
        logger -t vpn-domain-refresh "DNS configuration changed; old VPN IPs cleared"
    fi

    echo "conf-file=$VPN_CONF" >> "$CONFIG"
    printf '%s\n' "$hash" > "$STAMP"
fi
VPNDOMAIN_LEGACY_DNS_END
    cat > "$WORK/legacy-cron" <<'VPNDOMAIN_LEGACY_CRON_END'
cru a VPNDomainRoutingHealth \
    "* * * * * /jffs/scripts/vpn-domain-routing.sh apply"
VPNDOMAIN_LEGACY_CRON_END
    cat > "$WORK/legacy-delay" <<'VPNDOMAIN_LEGACY_DELAY_END'
(
    sleep 15
    /jffs/scripts/vpn-domain-refresh.sh
) &
VPNDOMAIN_LEGACY_DELAY_END
}

# Human-readable entry points: no implicit installation.
banner() {
    printf '\n============================================================\n'
    printf ' VPN Domains %s - installer and maintenance tool\n' "$VERSION"
    printf '============================================================\n'
    cat <<'INTRO'
Routes IPv4 traffic for listed domains through an existing WireGuard client.
Includes a native router page: LAN -> VPN Domains.
Applies to all local networks; DNS filtering is not bypassed.
WireGuard only. This tool does not create or start the VPN client.
INTRO
}
usage() {
    printf '\nUsage: sh %s [command]\n\n' "$0"
    cat <<'USAGE'
  (no command)   Show the main menu. Does NOT start installation.
  install        Fresh installation, or WebUI-only repair of an active backend.
  configure-vpn  Explicit VPN change, legacy migration, or re-enable.
  check          Compatibility checks only; no configuration changes.
  test-menu      Test WireGuard discovery/selection only; nothing is saved.
  status         Show the current installation and routing state.
  uninstall      Disable integration; keep the allowlist and addon files.
  purge --yes    Remove integration AND addon/data files (asks for YES).
  help           Show this help.
USAGE
}
main_menu() {
    [ -r /dev/tty ] && [ -w /dev/tty ] || { usage; echo 'No interactive terminal; specify a command.'; return 1; }
    cat > /dev/tty <<'MENU'

Main menu - no installation has started:

  1) Install / repair WebUI
  2) Configure WireGuard / migrate / re-enable
  3) Check compatibility (no configuration changes)
  4) Test WireGuard selection (no configuration changes)
  5) Show status
  6) Uninstall integration (keep data; asks for YES)
  7) Purge integration and data (destructive; asks for YES)
  0) Exit
MENU
    while :; do
        printf '\nChoose an action [0-7]: ' > /dev/tty
        IFS= read -r menu_choice < /dev/tty || return 1
        case "$menu_choice" in
            0|q|Q) ACTION=exit; return 0 ;;
            1) ACTION=install; return 0 ;;
            2) ACTION=configure-vpn; return 0 ;;
            3) ACTION=check; return 0 ;;
            4) ACTION=test-menu; return 0 ;;
            5) ACTION=status; return 0 ;;
            6) ACTION=uninstall; return 0 ;;
            7) ACTION=purge; PURGE_FLAG=--yes; return 0 ;;
            *) printf 'Enter a number from 0 to 7, or q to exit.\n' > /dev/tty ;;
        esac
    done
}
show_action_plan() {
    printf '\nSelected action: %s\n' "$ACTION"
    case "$ACTION" in
        install)
            if [ -f "$DIR/.disabled" ]; then
                echo 'The previous installation is disabled.'
                echo 'No fresh install or automatic re-enable will be performed.'
                echo 'Use configure-vpn to explicitly re-enable; use purge for a clean cycle.'
            elif backend_exists; then
                cat <<'PLAN'
Mode: existing backend / WebUI repair.
Will restore the page, its support files and two marked WebUI hook blocks.
Will NOT select another VPN, rewrite backend scripts, change the allowlist,
restart DNS, or apply routing rules as part of this repair.
PLAN
            else
                cat <<'PLAN'
Mode: fresh installation (subject to compatibility and partial-install checks).

Installation steps:
  1. Check the router environment and existing integration.
  2. Find ready WireGuard clients and ask you to select one.
  3. Show the selected interface/table and ask you to type YES.
  4. Back up affected files outside the addon directory.
  5. Create backend scripts, routing settings and marked hook blocks.
  6. Keep an existing allowlist, or create an empty commented allowlist.
  7. Restart dnsmasq and apply domain-routing rules for the selected tunnel.
  8. Install LAN -> VPN Domains and enable the health cron job.

Locations:
  Addon/WebUI: /jffs/addons/vpn-domain
  Backend:     /jffs/scripts/vpn-domain-*.sh
  Allowlist:   /jffs/configs/vpn-domain-allowlist.txt
  Backups:     /jffs/vpn-domain-backups

No local-network selection: domain routing applies to all local networks.
Does not configure/start WireGuard or change DNS-filter policies.
DNS will restart during installation. No VPN kill switch is installed.
No backend/configuration changes are applied before your YES confirmation.
PLAN
            fi
            ;;
        configure-vpn)
            echo 'Will select WireGuard, then request YES before changing backend/integration.'
            echo 'A changed binding/migration/re-enable restarts DNS; the allowlist is kept.'
            echo 'An unchanged active managed binding is left untouched.' ;;
        check) echo 'Read-only compatibility and hook-planning checks. No configuration is applied.' ;;
        test-menu) echo 'Discovery/selection test only. Even a selected client will NOT be saved or applied.' ;;
        status) echo 'Shows current state only.' ;;
        uninstall)
            echo 'Will request YES, back up files, remove our hooks/cron/routing and restart DNS.'
            echo 'The allowlist, WireGuard client and addon/backend files are kept.' ;;
        purge)
            echo 'DESTRUCTIVE: removes our integration, backend, settings, allowlist and addon directory.'
            echo 'Requests YES. External backups and unrelated integrations are kept.' ;;
    esac
}
wireguard_help() {
    cat <<'WGHELP'

A ready WireGuard CLIENT must already exist before installation.

NOTE: You can use free PROTON VPN service: https://protonvpn.com

On Asuswrt-Merlin:
  1. Open the router WebUI -> VPN -> VPN Client.
  2. Select WireGuard as the VPN protocol and choose the client profile.
  3. If needed, choose/import the provider's .conf file and click Upload.
  4. Set Enable WireGuard to Yes and click Apply.
  5. Wait for Connected, then retry this installer.

If your firmware calls this page VPN Fusion:
  VPN -> VPN Fusion -> Add profile -> WireGuard -> Upload Config,
  save the profile and enable that VPN connection.

Do not add an all-devices/default-VPN rule just to satisfy this installer.
VPN Domains adds its own domain-based routing after confirmation.

Ready-client checks:
  - interface named wgcN;
  - an IPv4 address;
  - a routing-table mapping for that client;
  - default or both half-default IPv4 routes through that interface;
  - at least one handshake no older than 180 seconds.

If the profile is already enabled but the handshake is old:
  inspect VPN -> VPN Client and the connection status, wait/reconnect as needed,
  then retry. Do not change DNS filters or route all devices into the VPN.

Manual diagnostics (read-only):
  wg show interfaces
  wg show wgc1 latest-handshakes
  ip -4 addr show dev wgc1
  ip -4 route show table wgc1
  (Replace wgc1 with the client you are checking.)

No backend, allowlist, hooks, cron or routing changes were applied by this
selection attempt. Cancel with q whenever the selection prompt is shown.
WGHELP
}
client_reason() {
    probe_iface="$1"; probe_table="$2"
    if ! ip -4 addr show dev "$probe_iface" 2>/dev/null | grep -q 'inet '; then echo 'no IPv4 address'; return; fi
    if ! ip -4 route show table "$probe_table" 2>/dev/null | awk -v iface="$probe_iface" '
      {ok=0;for(i=1;i<NF;i++)if($i=="dev" && $(i+1)==iface)ok=1}
      ok && $1=="default"{full=1}
      ok && $1=="0.0.0.0/1"{lower=1}
      ok && $1=="128.0.0.0/1"{upper=1}
      END{exit !(full || (lower && upper))}'; then echo 'full IPv4 tunnel routes are missing'; return; fi
    probe_age="$(wg show "$probe_iface" latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '
      $2 ~ /^[0-9]+$/ && $2>0 && $2<=now {a=now-$2;if(!seen || a<best)best=a;seen=1}
      END{if(seen)print best;else print "none"}')"
    case "$probe_age" in none) echo 'no successful handshake';; *) printf 'last handshake %ss ago (maximum 180s)\n' "$probe_age";; esac
}
select_wireguard() {
    [ -r /dev/tty ] && [ -w /dev/tty ] || die 'Interactive terminal required. Run this command in an SSH terminal.'
    candidates="$WORK/wireguard-candidates"
    : > "$candidates"
    n=0
    printf '\nStep: choose the existing WireGuard client for domain routing.\n' > /dev/tty
    printf 'Only ready WireGuard clients are selectable. No settings have been applied.\n\n' > /dev/tty
    for iface in $(wg show interfaces 2>/dev/null); do
        case "$iface" in wgc[1-9]|wgc[1-9][0-9]) ;; *) continue ;; esac
        table="$(find_table "$iface")" || { printf '  Skipped %s: routing-table mapping not found.\n' "$iface" > /dev/tty; continue; }
        case "$table" in ''|*[!0-9]*) continue ;; esac
        [ "$table" -gt 0 ] && [ "$table" -lt 253 ] || continue
        if ! candidate_ready "$iface" "$table"; then
            printf '  Skipped %s: %s.\n' "$iface" "$(client_reason "$iface" "$table")" > /dev/tty
            continue
        fi
        n=$((n+1))
        address="$(ip -4 addr show dev "$iface" | awk '/inet /{print $2;exit}')"
        printf '  %s) %s | IPv4: %s | routing table: %s | ready\n' "$n" "$iface" "$address" "$table" > /dev/tty
        printf '%s %s\n' "$iface" "$table" >> "$candidates"
    done
    if [ "$n" -eq 0 ]; then
        echo 'No ready WireGuard client found.'
        wireguard_help
        exit 1
    fi
    printf '\nChoose a client number, q to cancel, or h for setup instructions.\n' > /dev/tty
    while :; do
        printf 'WireGuard client [1-%s / q / h]: ' "$n" > /dev/tty
        IFS= read -r answer < /dev/tty || die 'Selection cancelled; no configuration changes applied.'
        case "$answer" in
            q|Q) echo 'Cancelled. No configuration changes applied.'; exit 0 ;;
            h|H|\?) wireguard_help > /dev/tty; continue ;;
            ''|*[!0-9]*) printf 'Enter a listed number, h or q.\n' > /dev/tty; continue ;;
        esac
        [ "${#answer}" -le 3 ] || continue
        answer="$(printf '%s' "$answer" | sed 's/^0*//')"
        [ -n "$answer" ] && [ "$answer" -ge 1 ] && [ "$answer" -le "$n" ] || continue
        WG_INTERFACE="$(awk -v n="$answer" 'NR==n{print $1}' "$candidates")"
        WG_TABLE="$(awk -v n="$answer" 'NR==n{print $2}' "$candidates")"
        printf '\nSelected: %s, IPv4 routing table %s.\n' "$WG_INTERFACE" "$WG_TABLE" > /dev/tty
        if [ "$ACTION" = test-menu ]; then
            printf 'Test mode: selection will NOT be saved or applied.\n' > /dev/tty
        else
            printf 'Selection alone does not apply changes. Confirmation follows.\n' > /dev/tty
        fi
        break
    done
}

ACTION="${1:-}"
PURGE_FLAG="${2:-}"
banner
case "$ACTION" in
    help|-h|--help) usage; exit 0 ;;
    '') main_menu || exit 1 ;;
esac
case "$ACTION" in
    exit) echo 'Exited. No installation started.'; exit 0 ;;
    install|configure-vpn|check|test-menu|status|uninstall) ;;
    purge) [ "$PURGE_FLAG" = --yes ] || { usage; echo 'For full deletion use purge --yes; YES confirmation is also required.'; exit 1; } ;;
    *) usage; printf '\nUnknown command: %s\n' "$ACTION"; exit 1 ;;
esac
require_root
show_action_plan
if [ "$ACTION" = status ]; then status_main; exit $?; fi
lock_install
stage="/tmp/vpn-domain-install.$$"
if (umask 077; mkdir "$stage"); then WORK="$stage"; else die "Cannot create temporary staging directory: $stage"; fi
emit_assets
for embedded in "$WORK/"*.sh; do sh -n "$embedded" || die "Embedded shell syntax error: ${embedded##*/}"; done
case "$ACTION" in
    install) install_main ;;
    configure-vpn) configure_vpn ;;
    check) check_main ;;
    test-menu) test_menu_main ;;
    uninstall) uninstall_main ;;
    purge) purge_main purge "$PURGE_FLAG" ;;
esac
