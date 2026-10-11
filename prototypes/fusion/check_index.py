# Check that extracted frame indexes match the overlay pictures of the Zig tool.
import cv2, numpy as np, os
cv2.setNumThreads(4)
# The overlay pictures of `fastest-scan --debug-dir .cache/debug`, from the repository root.
D=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '.cache', 'debug', 'frames')
for n in [465,480,495,510,570,795,810,915,1065,1080,1155]:
    ov=cv2.imread(f'{D}/f_{n:06d}.jpg',0).astype(np.float32)
    out=[]
    for k in range(-2,3):
        p=f'frames/f_{n+k:06d}.jpg'
        if not os.path.exists(p): out.append('  -  '); continue
        g=cv2.resize(cv2.imread(p,0),(960,540),interpolation=cv2.INTER_AREA).astype(np.float32)
        out.append(f'{np.mean(np.abs(g-ov)):5.2f}')
    print(n,' '.join(out),'(offsets -2..+2; min should be the middle)')
