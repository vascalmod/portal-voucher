# 5–6. Status generation, PAUSE/RESUME via ndsctl

## 5. Exact mechanism for status page generation

Separate MHD endpoint from preauth, handled by `client_params.sh` (`statuspath`).

* Args `client_params.sh:5-7`: `status=$1, clientip=$2, b64query=$3`.
* `parse_parameters:94-144`: if `status=status`, `97: ndsctl json $clientip`, parse allowlist at `103-107`:

  ```text
  gatewayname,gatewayaddress,gatewayfqdn,mac,version,ip,client_type,clientif,
  session_start,session_end,last_active,token,state,
  upload/download_rate_limit_threshold,upload/download_packet_rate,
  upload/download_bucket_size,upload/download_quota,
  upload/download_this_session,upload/download_session_avg
  ```

  via `108: grep "\"$param\":" | awk -F'"' '{print $4}'`, `110-112: null→Unlimited`.
* `122-138`: decode `gatewayname`, `get_client_zone`, `date -d @$session_start/@$session_end/@$last_active`.
* `320-346`: `url=http://$gatewayfqdn` (or `gatewayaddress` if disabled), decode `$b64query` into extra vars (e.g. `advanced`).
* `348-350`: `header; body; footer`.
* `body:193-287`: busy handling, `status` branch shows Logout `217: <form action="$url/opennds_deny/">`, Refresh `223: <form action="$url/">`, plus basic/advanced block `232-271`.

Critical: stock allowlist **omits `custom`**. `state/token` are parsed but never displayed. To show voucher/remaining/PAUSED, fork `client_params.sh` and add `custom` (raw `ndsctl json` + `b64decode`) + backend remaining lookup.

`status.html` mock does not map: no `opennds_deny`, no `advanced`, no MHD `$url`, static timer `30-32`.

`check_authenticated` (`libopennds.sh:578-597`) keys on `$status=authenticated` from FAS vars, not a general authed→status redirect; auto-showing status from preauth needs live verification.

Remote resources for status: `client_params.sh:294-315` calls `libopennds.sh download ... &>/dev/null` then `imagepath="ndsremote/logo.png"` or `images/splash.jpg`.

## 6. How `ndsctl auth`, `deauth`, `json` implement PAUSE/RESUME

* `auth`: `libopennds.sh:2791-2817` documents `mac|ip sessiontimeout uploadrate downloadrate uploadquota downloadquota encoded_customstring`. Live usage `auth_log:722` (`auth $rhid ...`), `preemptivemac:2087` (`"$mac, $sessiontimeout, ... preemptivemac-$mac"`), `authmon.sh:184` (`auth $authparams`). `rhid=sha256(hid+key)` is preauth token; direct `mac` also accepted per verified `ndsctl -h`.
* `deauth`: wrappers `libopennds.sh:2848-2889` (`deauth` + `daemon_deauth`). Stock Logout uses `GET $url/opennds_deny/` (`client_params.sh:217`).
* `json`: `client_params.sh:97-119` pattern `ndsctl json $clientip` + `grep/awk` parse.

PAUSE = `ndsctl deauth <mac|ip|token>` + backend freezes `remaining = prev_remaining - (now - resume_ts)`.
RESUME = `ndsctl auth <mac> <remaining_mins_ceil> <up_rate> <down_rate> 0 0 <b64 voucher...>` (rates ~10240 for 10 Mbps — units need live verification, themes comment `kb/s` at `theme_*basic.sh:430-431`).

Granularity: `auth_restore:1741-1742` computes `sessiontimeout=$(($session_left/60))`, confirming **minutes**. Sub-minute sessions round; backend must over-grant then correct on deauth callback.
