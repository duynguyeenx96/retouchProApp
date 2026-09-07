import json, urllib.request, os, hashlib, sys
import numpy as np, cv2
UA={'User-Agent':'RetouchProSpike/0.1 (research)'}
cands=json.load(open('candidates.json'))
os.makedirs('images/raw',exist_ok=True)
import mediapipe as mp
from mediapipe.tasks import python as mpp
from mediapipe.tasks.python import vision
opts=vision.FaceLandmarkerOptions(
    base_options=mpp.BaseOptions(model_asset_path='models/face_landmarker_v2_with_blendshapes.task', delegate=mpp.BaseOptions.Delegate.CPU),
    running_mode=vision.RunningMode.IMAGE, num_faces=2)
lm=vision.FaceLandmarker.create_from_options(opts)
kept=[]
for i,c in enumerate(cands):
    if len(kept)>=20: break
    p='images/raw/c%03d.jpg'%i
    if not os.path.exists(p):
        try:
            d=urllib.request.urlopen(urllib.request.Request(c['url'],headers=UA),timeout=60).read()
        except Exception as e:
            print('dlerr',i,e); continue
        open(p,'wb').write(d)
    img=cv2.imread(p)
    if img is None: os.remove(p); continue
    h,w=img.shape[:2]
    if min(h,w)<600: os.remove(p); continue
    rgb=cv2.cvtColor(img,cv2.COLOR_BGR2RGB)
    r=lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB,data=rgb))
    if len(r.face_landmarks)!=1: os.remove(p); continue
    pts=np.array([[l.x*w,l.y*h] for l in r.face_landmarks[0]])
    fw=pts[:,0].max()-pts[:,0].min(); fh=pts[:,1].max()-pts[:,1].min()
    if fw<260 or fh<260: os.remove(p); continue
    kept.append({'file':p,'title':c['title'],'url':c['url'],'license':c['license'],'cat':c['cat'],
                 'img_w':w,'img_h':h,'face_w':round(float(fw),1),'face_h':round(float(fh),1),
                 'sha256':hashlib.sha256(open(p,'rb').read()).hexdigest()})
    print('KEEP',p,c['title'][:60],w,h,round(fw),round(fh))
json.dump(kept,open('images/manifest_commons.json','w'),indent=1)
print('kept',len(kept))
