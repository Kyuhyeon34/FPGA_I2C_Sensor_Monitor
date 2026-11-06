"""Create a standalone, interactive digital scope view from actual XSim CSV edges."""
import argparse
import csv
import json
from pathlib import Path


def read_csv(path):
    with path.open(encoding="utf-8", newline="") as source:
        return list(csv.DictReader(source))


HTML = r'''<!doctype html>
<html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>I2C 센서별 파형</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#0b1018;color:#e4edf9;font:15px system-ui,sans-serif}
main{max-width:1180px;margin:auto;padding:28px 20px}h1{font-size:25px;margin:0 0 9px}p{color:#aebdd0;line-height:1.65}
.controls{display:flex;gap:16px;flex-wrap:wrap;align-items:center;margin:22px 0}label{display:flex;gap:9px;align-items:center}
select,button{background:#182334;color:#e4edf9;border:1px solid #40506a;border-radius:6px;padding:8px;font:inherit}
button{cursor:pointer}.screen{background:#080d14;border:1px solid #334155;border-radius:10px;overflow:auto}
svg{display:block;width:100%;min-width:700px}text{font:13px ui-monospace,Consolas,monospace;fill:#cbd5e1}
.packet{padding:16px 0;font:15px/1.8 ui-monospace,Consolas,monospace;color:#a5f3fc;overflow-wrap:anywhere}
.bytes{display:flex;gap:8px;flex-wrap:wrap}footer{margin-top:20px;color:#9baec6;line-height:1.7;font-size:14px}
.yellow{color:#facc15}.cyan{color:#22d3ee}input[type=range]{width:210px}#scale{color:#c4b5fd}
</style><main>
<h1>I2C 센서별 파형</h1>
<p>XSim에서 기록한 SDA/SCL 전이입니다. <span class="yellow">CH1 = SCL</span>, <span class="cyan">CH2 = SDA</span>.
센서와 확대 배율을 선택하고, 바이트 버튼을 누르면 해당 구간으로 이동합니다.</p>
<div class="controls"><label>캡처 <select id="capture"></select></label>
<label>확대 <select id="zoom"><option value="1">전체 패킷</option><option value="2">2배</option><option value="5">5배</option><option value="10">10배</option></select></label>
<label>좌우 이동 <input id="pan" type="range" min="0" max="1000" value="0"></label><span id="scale"></span></div>
<div class="screen"><svg id="scope" viewBox="0 0 1100 370" role="img" aria-label="I2C SCL 및 SDA 디지털 파형"></svg></div>
<div class="packet" id="packet"></div><div class="bytes" id="bytes"></div>
<footer>바이트는 MSB부터 8비트, 9번째 클럭은 ACK(0) 또는 NACK(1)입니다. 첫 DATA 뒤 ACK와 마지막 DATA 뒤 NACK는 Master가 보냅니다.
표시 전압 0/3.3V는 논리 0/1을 환산한 눈금입니다. 실제 상승시간·노이즈·오버슈트는 모델링하지 않습니다.
이 테스트는 선택 센서의 2바이트 읽기이며, 보드 기본 동작인 8바이트 전체 읽기와 구분됩니다.</footer>
<script id="data" type="application/json">__DATA__</script>
<script>
const data=JSON.parse(document.getElementById('data').textContent);
const cap=document.getElementById('capture'), zoom=document.getElementById('zoom'), pan=document.getElementById('pan');
const svg=document.getElementById('scope'), unit={1:'C',2:'%',3:'cm'}, names={1:'온도',2:'습도',3:'거리'};
function sensorValue(c){return String(c.value)+(c.sensor===1||c.fraction?'.'+c.fraction:'')+unit[c.sensor]}
data.captures.forEach((c,i)=>{const o=document.createElement('option');o.value=i;o.textContent=(i+1)+'. '+names[c.sensor]+' '+sensorValue(c);cap.append(o)});
function escape(s){return String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;')}
function current(){return data.captures[Number(cap.value)]}
function render(){
 const c=current(), factor=Number(zoom.value), base=c.start_ns-5000, total=c.end_ns-c.start_ns+10000;
 const span=total/factor, begin=base+(total-span)*Number(pan.value)/1000, end=begin+span;
 const x=t=>100+(t-begin)*970/span;
 let shapes='<defs><clipPath id="plot"><rect x="100" y="20" width="970" height="330"/></clipPath></defs>';
 for(let i=0;i<=10;i++){const px=100+97*i;shapes+='<path stroke="#243245" d="M'+px+' 30 V275"/>';
 shapes+='<text x="'+px+'" y="290" text-anchor="middle">'+((begin+span*i/10-c.start_ns)/1000).toFixed(1)+'</text>'}
 for(let y=45;y<=265;y+=22)shapes+='<path stroke="#172234" d="M100 '+y+' H1070"/>';
 shapes+='<text x="17" y="70" style="fill:#facc15">CH1 SCL</text><text x="17" y="180" style="fill:#22d3ee">CH2 SDA</text>';
 shapes+='<text x="48" y="94">3.3V</text><text x="65" y="149">0V</text><text x="48" y="204">3.3V</text><text x="65" y="259">0V</text>';
 shapes+='<text x="1070" y="364" text-anchor="end">time from request (us)</text><g clip-path="url(#plot)">';
 function trace(index,high,low,color){
   let level=1;
   for(const e of data.edges){if(e[0]<=begin)level=e[index];else break}
   let points='M100 '+(level?high:low);
   for(const e of data.edges){if(e[0]<=begin)continue;if(e[0]>end)break;
     if(e[index]!==level){points+=' H'+x(e[0]).toFixed(2)+' V'+(e[index]?high:low);level=e[index]}}
   return '<path d="'+points+' H1070" fill="none" stroke="'+color+'" stroke-width="2"/>';
 }
 shapes+=trace(1,90,145,'#facc15')+trace(2,200,255,'#22d3ee');
 for(const event of data.events.filter(e=>e.capture===c.capture)){
   if(event.time_ns>=begin&&event.time_ns<=end){const px=x(event.time_ns);
     shapes+='<path d="M'+px+' 35 V270" stroke="#a78bfa" stroke-dasharray="3 5"/>';
     shapes+='<text x="'+(px+4)+'" y="28" style="fill:#c4b5fd">'+escape(event.event)+'</text>'}}
 const bytes=data.bytes.filter(b=>b.capture===c.capture);
 for(const b of bytes){const left=x(b.start_ns),right=x(b.end_ns);
   if(right<100||left>1070)continue;
   shapes+='<rect x="'+left+'" y="310" width="'+(right-left)+'" height="27" rx="3" fill="'+(b.index<4?'#1e3a5f':'#155e65')+'"/>';
   if(right-left>45)shapes+='<text x="'+((left+right)/2)+'" y="328" text-anchor="middle">'+b.hex+' '+(b.ack?'A':'N')+'</text>';
 }
 shapes+='</g>';svg.innerHTML=shapes;
 document.getElementById('scale').textContent=(span/10000).toFixed(2)+' us/div';pan.disabled=factor===1;
 document.getElementById('packet').textContent='S 84 A '+c.register+' A Sr 85 A '+c.byte0+' A '+c.byte1+' N P   |   '+names[c.sensor]+' '+sensorValue(c);
 const buttons=document.getElementById('bytes');buttons.replaceChildren();
 for(const b of bytes){const button=document.createElement('button');button.textContent=b.phase+' : '+b.hex+' '+(b.ack?'ACK':'NACK');
   button.onclick=()=>{zoom.value='5';const width=total/5,center=(b.start_ns+b.end_ns)/2;
     pan.value=Math.max(0,Math.min(1000,1000*(center-width/2-base)/(total-width)));render()};buttons.append(button)}
}
cap.onchange=()=>{pan.value=0;zoom.value=1;render()};zoom.onchange=render;pan.oninput=render;render();
</script></main></html>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path(__file__).resolve().parent / "build")
    parser.add_argument("--prefix", default="i2c_scope")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root, prefix = args.build_dir, args.prefix
    captures = read_csv(root / (prefix + "_captures.csv"))
    byte_rows = read_csv(root / (prefix + "_bytes.csv"))
    events = read_csv(root / (prefix + "_events.csv"))
    edges = []
    for row in read_csv(root / (prefix + "_edges.csv")):
        if row["scl"] in ("0", "1") and row["sda"] in ("0", "1"):
            edge = [float(row["time_ns"]), int(row["scl"]), int(row["sda"])]
            if edges and edge[0] < edges[-1][0]:
                raise ValueError("Non-monotonic waveform timestamps")
            edges.append(edge)
    for row in captures:
        for key in ("capture", "sensor", "value"):
            row[key] = int(row[key])
        row["fraction"] = int(row.get("fraction", "0"))
        for key in ("start_ns", "end_ns"):
            row[key] = float(row[key])
        for key in ("register", "byte0", "byte1"):
            row[key] = row[key].upper()
    for row in byte_rows:
        for key in ("capture", "index", "ack"):
            row[key] = int(row[key])
        for key in ("start_ns", "end_ns"):
            row[key] = float(row[key])
        row["hex"] = row["hex"].upper()
    for row in events:
        row["capture"] = int(row["capture"])
        row["time_ns"] = float(row["time_ns"])
    if not captures or not edges:
        raise ValueError("No simulation captures; run tb_i2c_scope first")
    for capture in captures:
        actual = [b for b in byte_rows if b["capture"] == capture["capture"]]
        expected = ["84", capture["register"], "85", capture["byte0"], capture["byte1"]]
        if [b["hex"] for b in actual] != expected or [b["ack"] for b in actual] != [1, 1, 1, 1, 0]:
            raise ValueError("Captured protocol/ACK sequence is inconsistent")
    data = json.dumps(dict(captures=captures, bytes=byte_rows, events=events, edges=edges), ensure_ascii=False)
    output = args.output or root / (prefix + ".html")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(HTML.replace("__DATA__", data.replace("<", "\\u003c")), encoding="utf-8")
    print(f"PASS: rendered {len(captures)} captures, {len(edges)} recorded bus transitions: {output}")


if __name__ == "__main__":
    main()
