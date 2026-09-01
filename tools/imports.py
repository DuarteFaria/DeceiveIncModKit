import struct,sys
p=sys.argv[1]
d=open(p,'rb').read()
pe=struct.unpack('<I',d[0x3c:0x40])[0]
magic=struct.unpack('<H',d[pe+24:pe+26])[0]
opt=pe+24
nsec=struct.unpack('<H',d[pe+6:pe+8])[0]
optsz=struct.unpack('<H',d[pe+20:pe+22])[0]
# data dir 1 = import
ddoff = opt + (112 if magic==0x20b else 96)
imp_rva,imp_sz=struct.unpack('<II',d[ddoff+8:ddoff+16])
secs=[]
for i in range(nsec):
    o=pe+24+optsz+i*40
    vsz,va,rsz,ptr=struct.unpack('<IIII',d[o+8:o+24])
    secs.append((va,vsz,ptr,rsz))
def rva2off(r):
    for va,vsz,ptr,rsz in secs:
        if va<=r<va+max(vsz,rsz): return ptr+(r-va)
    return None
off=rva2off(imp_rva)
names=[]
while True:
    ent=d[off:off+20]
    if len(ent)<20 or ent==b'\0'*20: break
    name_rva=struct.unpack('<I',ent[12:16])[0]
    if name_rva==0: break
    no=rva2off(name_rva)
    s=d[no:d.index(b'\0',no)].decode('latin1')
    names.append(s)
    off+=20
for n in sorted(set(names),key=str.lower): print(" ",n)
print(len(set(names)),"imported DLLs")
