"""Disk-indexed JSONL batches for datasets too large for encoded RAM caches."""
import json
import struct
from pathlib import Path

import numpy as np

from common import validate


class IndexedJSONL:
    def __init__(self,path,index_path,privacy):
        self.path=Path(path)
        index_path=Path(index_path)
        # Caller validates the complete dataset SHA before using any cache.
        if not index_path.exists():
            temporary=index_path.with_suffix('.tmp')
            with self.path.open('rb') as source,temporary.open('wb') as index:
                while True:
                    offset=source.tell()
                    line=source.readline()
                    if not line:
                        break
                    if not line.strip():
                        continue
                    record=json.loads(line)
                    validate(record,True)
                    if privacy=='public' and (record.get('privacy')=='private' or record.get('origin')=='dogfood'):
                        raise ValueError('private record in public training manifest')
                    index.write(struct.pack('<Q',offset))
            temporary.replace(index_path)
        if index_path.stat().st_size==0:
            raise ValueError('empty training split')
        if index_path.stat().st_size%8:
            raise ValueError('corrupt JSONL offset index')
        self.offsets=np.memmap(index_path,dtype='<u8',mode='r')

    def __len__(self):
        return len(self.offsets)

    def read(self,indices):
        result=[]
        with self.path.open('rb') as source:
            for i in indices:
                source.seek(int(self.offsets[int(i)]))
                result.append(json.loads(source.readline()))
        return result
