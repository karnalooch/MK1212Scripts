#!/usr/bin/env python3
"""Analyze two bounded MK1212_STEAMWORKS_TRACE.log files from instrumented Goldberg x86."""
import argparse
from collections import Counter
from pathlib import Path
import json
import re
import sys

EVENTS = {
    "CreateLobby.call","CreateLobby.return","LobbyCreated.callback",
    "RequestLobbyList.call","RequestLobbyList.return","LobbyMatchList.callback",
    "RequestLANServerList.call","RequestLANServerList.return","ServerList.callback",
    "SetLobbyData.call","JoinLobby.call","InviteUserToLobby.call",
    "InviteUserToGame.call","ActivateGameOverlayInviteDialog.call"
}
RE = re.compile(r"^(\d{9,12})\|(\d+)\|([A-Za-z][A-Za-z0-9.]+)\|(.*)$")
MAX_BYTES=2097152

def read_trace(path: Path):
    if not path.is_file():
        return {"status":"NOT_PROVIDED","events":[],"counts":{}}
    if path.stat().st_size > MAX_BYTES:
        return {"status":"OVERSIZE_REFUSED","events":[],"counts":{}}
    events=[]
    text=path.read_text(encoding="utf-8",errors="replace")
    for line in text.splitlines():
        m=RE.fullmatch(line)
        if not m or m.group(3) not in EVENTS:
            continue
        fields=dict(re.findall(r"([a-z_]+)=([a-zA-Z0-9]+)",m.group(4)))
        events.append({"epoch":int(m.group(1)),"pid":int(m.group(2)),
            "event":m.group(3),"fields":fields})
    counts=dict(sorted(Counter(e["event"] for e in events).items()))
    status="TRACE_PRESENT" if events else "NO_RECOGNIZED_TRACE_EVENTS"
    return {"status":status,"events":events,"counts":counts}

def diagnose(host,client):
    if host["status"]!="TRACE_PRESENT" or client["status"]!="TRACE_PRESENT":
        return "INCOMPLETE: cannot infer missing calls without valid independent HOST and CLIENT traces"
    hc=host["counts"]; cc=client["counts"]
    out=[]
    if hc.get("CreateLobby.call",0)==0 and hc.get("RequestLANServerList.call",0)==0:
        out.append("HOST: no captured Steamworks CreateLobby or LAN-server-list calls; inspect game's hosting path")
    if hc.get("CreateLobby.call",0)>0:
        if hc.get("LobbyCreated.callback",0)==0:
            out.append("HOST: CreateLobby called but no LobbyCreated callback captured")
        elif any(e["event"]=="LobbyCreated.callback" and e["fields"].get("result")=="fail" for e in host["events"]):
            out.append("HOST: lobby creation returned a failure callback")
        else:
            out.append("HOST: lobby creation callback observed; inspect visibility/search filters")
    if cc.get("RequestLobbyList.call",0)==0 and cc.get("RequestLANServerList.call",0)==0:
        out.append("CLIENT: no captured RequestLobbyList or RequestLANServerList calls; inspect game-specific discovery")
    if cc.get("RequestLobbyList.call",0)>0 and cc.get("LobbyMatchList.callback",0)==0:
        out.append("CLIENT: RequestLobbyList called but no LobbyMatchList callback captured")
    if any(e["event"]=="LobbyMatchList.callback" and e["fields"].get("matches")=="0" for e in client["events"]):
        out.append("CLIENT: LobbyMatchList callback returned 0 matches")
    if any(e["event"]=="ServerList.callback" and e["fields"].get("matches")=="0" for e in client["events"]):
        out.append("CLIENT: server-list callback returned 0 matches")
    return "; ".join(out) if out else "API calls/callbacks present; correlate with game UI and network capture"

def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host",required=True,type=Path)
    ap.add_argument("--client",required=True,type=Path)
    ap.add_argument("--output",type=Path,help="New JSON output path")
    args=ap.parse_args(argv)
    host=read_trace(args.host)
    client=read_trace(args.client)
    report={"schema":1,"test_status":"OBSERVATION_ONLY","host":host,"client":client,
            "diagnosis":diagnose(host,client)}
    data=json.dumps(report,indent=2,ensure_ascii=False)+"\n"
    if args.output:
        if args.output.exists():
            raise SystemExit("Refusing to overwrite an existing report")
        args.output.write_text(data,encoding="utf-8")
    print(data)
    return 0
if __name__=="__main__":
    raise SystemExit(main())
