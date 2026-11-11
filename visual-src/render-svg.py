#!/usr/bin/env python3
"""Render the interface illustrations with a file-only SVG renderer.

The SVGs are source-based drawings, not native macOS captures. This renderer
uses Inkscape, Node.js, and Python's standard library, and makes no requests.
"""
from pathlib import Path
import html
import json
import re
import subprocess

root=Path(__file__).resolve().parent.parent
source=(root/'visual-src/features.html').read_text()
symbols={name:(view,body) for name,view,body in re.findall(r'<symbol id="([^"]+)" viewBox="([^"]+)">(.*?)</symbol>',source,re.S)}
art_js=re.search(r'<script>(.*?)</script>',source,re.S).group(1).split('const scenes=')[0]
art_json=subprocess.run(['node','-e',art_js+'\nprocess.stdout.write(JSON.stringify({coast:landscape("coast"),mountain:landscape("mountain"),field:landscape("field")}));'],capture_output=True,text=True,check=True).stdout
art=json.loads(art_json)
assets=root/'assets'
assets.mkdir(exist_ok=True)
parts=[]

def add(value): parts.append(value)
def rect(x,y,w,h,fill,rx=0,stroke=None,sw=1):
    opacity=''
    if re.fullmatch(r'#[0-9a-fA-F]{8}',fill):
        opacity=f' fill-opacity="{int(fill[-2:],16)/255:.5f}"'
        fill=fill[:7]
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{opacity}'+(f' stroke="{stroke}" stroke-width="{sw}"' if stroke else '')+'/>')
def line(x1,y1,x2,y2,color='#ddd9e5',width=1):
    add(f'<path d="M{x1} {y1}L{x2} {y2}" stroke="{color}" stroke-width="{width}" fill="none"/>')
def text(x,y,value,size=12,color='#40394c',weight=400,anchor='start',spacing=0):
    add(f'<text x="{x}" y="{y}" font-family="Arial, sans-serif" font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" letter-spacing="{spacing}" fill="{color}">{html.escape(value)}</text>')
def icon(name,x,y,size=16,color='#827a90'):
    view,body=symbols[name]
    add(f'<svg x="{x}" y="{y}" width="{size}" height="{size}" viewBox="{view}" color="{color}" stroke="{color}" fill="none" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">{body}</svg>')
def image(kind,x,y,w,h,rounding=0):
    raw=art[kind]
    suffix=f'-{len(parts)}'
    raw=re.sub(r'id="([^"]+)"',lambda m:'id="'+m.group(1)+suffix+'"',raw)
    raw=re.sub(r'url\(#([^)]+)\)',lambda m:'url(#'+m.group(1)+suffix+')',raw)
    raw=re.sub(r'<svg ',f'<svg x="{x}" y="{y}" width="{w}" height="{h}" ',raw,count=1)
    cid=f'clip{len(parts)}'
    add(f'<defs><clipPath id="{cid}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rounding}"/></clipPath></defs><g clip-path="url(#{cid})">')
    add(raw)
    add('</g>')
def button(x,y,w,label,primary=False,disabled=False):
    fill='#e7e4ec' if disabled else ('#6e5ce0' if primary else '#fff')
    col='#aaa4b6' if disabled else ('#fff' if primary else '#4a4356')
    rect(x,y,w,30,fill,6,'#ddd9e3' if disabled else ('#6854cd' if primary else '#d7d3df'))
    text(x+w/2,y+19,label,11,col,500,'middle')
def section(y,label):text(20,y,label,9,'#8d8897',650,spacing=1.1)
def toggle(x,y,on=True):
    rect(x,y,28,17,'#6e5ce0' if on else '#cfccd6',9)
    add(f'<circle cx="{x+(19.5 if on else 8.5)}" cy="{y+8.5}" r="6.5" fill="white"/>')

def side(output):
    apple=output=='Apple Live Photo'
    rect(0,30,248,690,'#eeeef3')
    line(248,30,248,720,'#d6d5df')
    rect(20,50,40,40,'url(#brand)',10)
    icon('live',26.5,56.5,27,'white')
    text(69,68,'MotionPhotoBridge',16,'#272735',650)
    text(69,85,'Keep every moment moving.',9.5,'#7b7885')
    rect(20,117,208,62,'#e6e2f3',12)
    icon('viewfinder',34,131,12,'#534f61')
    text(53,141,'Automatic detection',12,'#534f61',550)
    text(34,162,'Apple · Google · Samsung',11.5,'#777383')
    section(210,'CONVERT TO')
    rect(20,220,208,29,'#fdfdfe',6,'#c7c4ce')
    text(29,239,output,11,'#3d3948',500)
    icon('chev',207,228,12)
    text(20,267,'JPEG + MOV pair' if apple else 'One JPEG with embedded MP4',10,'#7a7584')
    section(296,'SAVE IN')
    rect(20,307,208,57,'#fcfcfd',9,'#dddbe5')
    icon('folder',31,320,15,'#6e5ce0')
    text(54,328,'Converted Photos',11,'#40394c',550)
    text(54,342,'/Users/demo/Pictures/',9,'#8b8595')
    text(54,354,'Converted Photos',9,'#8b8595')
    icon('chev',204,323,10,'#aaa4b4')
    section(395,'CONVERSION')
    text(20,419,'Keep original audio',11)
    toggle(200,407)
    text(20,447,'Motion length',11)
    rect(20,457,208,26,'#dedce5',6,'#d6d3de')
    rect(22,459,101,22,'#fff',4)
    text(73,474,'3 seconds',10,'#443e50',400,'middle')
    text(175,474,'Full clip',10,'#746f80',400,'middle')
    for i,s in enumerate(['A short clip is centered on the original','photo’s capture time when available.']):text(20,501+i*14,s,10,'#827b8d')
    if apple:
        line(20,533,228,533)
        text(20,560,'Also add to Photos',11)
        toggle(200,548,False)
        for i,s in enumerate(['Ask for Photos access when you','convert. An export is always kept.']):text(20,586+i*14,s,10,'#827b8d')
    icon('shield',20,642,12,'#787283')
    text(38,652,'On your Mac. No uploads.',10,'#787283',550)
    for i,s in enumerate(['JPEG + H.264 video · Standard dynamic','range. HDR and gain maps aren’t preserved.']):text(20,671+i*13,s,9,'#787283')

def queue_row(y,name,format,kind,size,done=False):
    height=134 if done else 108
    rect(268,y,752,height,'#fff',12,'#e4e1e9')
    image(kind,281,y+22,58,58,9)
    text(352,y+25,name,12,'#40394c',600)
    badgewidth={'Apple Live Photo':112,'Google Motion Photo':133,'Samsung Motion Photo':144}[format]
    rect(352,y+33,badgewidth,22,'#f4f1fc',11)
    icon('link' if format=='Apple Live Photo' else 'photo',359,y+38,11,'#6e5ce0')
    text(374,y+47,format,9,'#6e5ce0',500)
    text(352,y+72,'Apple Live Photo exported' if done else 'Ready to convert',10,'#7f788b')
    if not done:text(352,y+87,size,9,'#aaa3b3')
    rect(941 if done else 952,y+13,66 if done else 55,21,'#e9f7f4' if done else '#f1eff4',11)
    icon('checkcircle' if done else 'circle',949 if done else 959,y+18,11,'#309e93' if done else '#9990a3')
    text(964 if done else 974,y+27,'Exported' if done else 'Ready',9,'#309e93' if done else '#9990a3',500)
    if done:
        icon('preview',938,y+45,14,'#a39aac');icon('folder',962,y+45,14,'#a39aac')
    icon('close',987,y+45,14,'#a39aac')
    if done:
        icon('turn',281,y+92,12,'#897f94')
        text(300,y+102,'Apple Live Photo',10,'#665c74',550)
        text(382,y+102,'JPEG + MOV pair',10,'#897f94')
        text(281,y+123,'Add this Live Photo to Photos',10,'#6e5ce0')

def app(key):
    done=key==3;count=3 if key==2 else 2;output='Google Motion Photo' if key==1 else 'Apple Live Photo'
    add('<g transform="translate(202 207) scale(1.15)">')
    rect(0,0,1040,720,'#f7f7f9',13,'#b4aebe')
    add('<g clip-path="url(#windowclip)">')
    rect(0,0,1040,30,'#efedf3')
    line(0,30,1040,30,'#d7d6de')
    for i,c in enumerate(['#ff5e58','#ffbd2f','#29c83f']):add(f'<circle cx="{20+i*18}" cy="15" r="5.5" fill="{c}" stroke="#00000012"/>')
    text(520,19,'MotionPhotoBridge',12,'#686570',600,'middle')
    side(output)
    text(274,78,'Your Photos',24,'#272735',650)
    text(274,99,f'{count} photos'+(f' · {count} exported' if done else ''),11,'#827c8d')
    button(897,64,70,'＋ Add⌄')
    button(979,64,35,'•••')
    line(248,132,1040,132,'#dfdce5')
    if key==1:
        queue_row(152,'IMG_2048.HEIC','Apple Live Photo','coast','8.4 MB')
        queue_row(269,'IMG_2057.HEIC','Apple Live Photo','mountain','10.2 MB')
    elif key==2:
        queue_row(152,'IMG_2048.HEIC','Apple Live Photo','coast','8.4 MB')
        queue_row(269,'PXL_20261111_142538_MP.jpg','Google Motion Photo','mountain','7.1 MB')
        queue_row(386,'20261111_152017.jpg','Samsung Motion Photo','field','9.6 MB')
    else:
        queue_row(152,'PXL_20261111_142538_MP.jpg','Google Motion Photo','coast','',True)
        queue_row(295,'20261111_152017.jpg','Samsung Motion Photo','field','',True)
    fy=639 if done else 658
    rect(249,fy,791,720-fy,'#fbfbfc');line(248,fy,1040,fy,'#dfdce5')
    if done:text(272,662,'Finished. 2 photos exported.',10,'#82798e')
    icon('folder',272,683,12,'#6e5ce0');text(291,693,'Open export folder',10,'#6e5ce0')
    button(870,675,146,'Convert Photos' if done else f'Convert {count} Photos',not done,done)
    add('</g>')
    if key==1:
        rect(14,227,231,96,'#fffffe',8,'#b8b1c8')
        text(41,250,'Apple Live Photo',11,'#474053')
        rect(19,260,221,28,'#6e5ce0',4)
        icon('check',27,268,12,'white');text(44,279,'Google Motion Photo',11,'white')
        text(41,307,'Samsung Motion Photo',11,'#474053')
        add('<path d="M217 279v21l5-5 5 9 4-2-5-9 8-1Z" fill="#33303b" stroke="white" stroke-width="1.5"/>')
    elif key==3:
        rect(0,30,1040,690,'#17102620')
        rect(160,71,720,580,'#f8f8fb',12,'#bbb5c8')
        text(180,104,'Apple Live Photo',14,'#272735',650)
        text(180,124,'PXL_20261111_142538_MP.jpg',11,'#867b91')
        button(799,91,61,'Done')
        rect(420,144,200,26,'#dedce5',6,'#d6d3de');rect(520,146,98,22,'#fff',4)
        text(470,162,'Photo',10,'#746f80',400,'middle');text(569,162,'Motion',10,'#443e50',400,'middle')
        rect(161,186,718,409,'#10171c')
        image('coast',161,186,718,409)
        rect(278,550,484,33,'#18242eeb',8,'#ffffff38')
        icon('play',290,560,13,'white');text(312,570,'0:01',9,'white')
        rect(346,565,274,3,'#ffffff55',2);rect(346,565,104,3,'white',2)
        add('<circle cx="450" cy="566.5" r="3.5" fill="white"/>')
        text(632,570,'0:03',9,'white');icon('volume',680,559,13,'white');icon('expand',728,559,13,'white')
        icon('link',177,618,12,'#81748e');text(197,628,'JPEG + MOV pair',11,'#81748e')
        button(750,608,112,'Show in Finder')
    add('</g>')

titles=[
('Choose where your motion goes.','Convert Apple Live Photos into Google or Samsung Motion Photos.'),
('Add your photos. We detect the format.','Mix Apple, Google, and Samsung originals in the same queue.'),
('Preview the moment. Keep the motion.','Check the photo and video, then reveal your export in Finder.')]
names=['01-format-picker','02-automatic-detection','03-preview-and-export']
for key,(title,desc) in enumerate(titles,1):
    parts=[]
    add('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1600" height="1100" viewBox="0 0 1600 1100"><defs><linearGradient id="brand" x2="1" y2="1"><stop stop-color="#6e5ce0"/><stop offset="1" stop-color="#3d8cec"/></linearGradient><radialGradient id="bg"><stop stop-color="#f5f4f8"/><stop offset="1" stop-color="#e9e5f3"/></radialGradient><clipPath id="windowclip"><rect width="1040" height="720" rx="13"/></clipPath></defs>')
    rect(0,0,1600,1100,'url(#bg)')
    text(202,60,'MOTIONPHOTOBRIDGE / FOR MAC',14,'#7468ac',650,spacing=2.5)
    text(202,125,title,47,'#272735',650,spacing=-1.6)
    text(202,167,desc,21,'#6b6977')
    app(key)
    text(202,1070,'Interface illustration · Based on MotionPhotoBridge 2 source',14,'#766a90',500)
    text(1398,1070,f'0{key} / 03',13,'#a29aa9',400,'end',1.3)
    add('</svg>')
    svg=root/'visual-src'/f'{names[key-1]}.svg'
    svg.write_text('\n'.join(parts))
    subprocess.run(['inkscape',str(svg),'--export-filename='+str(assets/(names[key-1]+'.png'))],check=True,capture_output=True)
    print(f'Rendered {names[key-1]}.png: 1600 × 1100, source-based SVG')
