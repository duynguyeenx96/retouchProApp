import json, urllib.request, urllib.parse, os, re, sys
UA={'User-Agent':'RetouchProSpike/0.1 (research; contact local)'}
CATS=["Category:Head shots","Category:Portrait photographs of women","Category:Portrait photographs of men",
      "Category:Smiling people","Category:Human faces","Category:Portrait photographs by Ailura"]
out=[]
for c in CATS:
    q={'action':'query','format':'json','generator':'categorymembers','gcmtitle':c,'gcmtype':'file',
       'gcmlimit':'40','prop':'imageinfo','iiprop':'url|size|extmetadata','iiurlwidth':'1600'}
    url='https://commons.wikimedia.org/w/api.php?'+urllib.parse.urlencode(q)
    try:
        d=json.load(urllib.request.urlopen(urllib.request.Request(url,headers=UA),timeout=60))
    except Exception as e:
        print('ERR',c,e); continue
    pages=d.get('query',{}).get('pages',{})
    print(c, len(pages))
    for k,v in pages.items():
        ii=(v.get('imageinfo') or [{}])[0]
        u=ii.get('thumburl') or ii.get('url')
        if not u or not re.search(r'\.(jpe?g|png)(\?|$)',u,re.I): continue
        lic=(ii.get('extmetadata') or {}).get('LicenseShortName',{}).get('value','?')
        out.append({'title':v['title'],'url':u,'w':ii.get('width'),'h':ii.get('height'),'license':lic,'cat':c})
json.dump(out,open('candidates.json','w'),indent=1)
print('total candidates',len(out))
