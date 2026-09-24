"""Per-experiment CPU/GPU latency without generating export artifacts."""
import argparse
from pathlib import Path

import torch

from common import write_json
from export import request,time_call
from train import load_model,tensor_batch


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    model,config,tk=load_model(a.model)
    torch.set_num_threads(4)
    report={}
    with torch.inference_mode():
        for device in ['cpu']+(['cuda'] if torch.cuda.is_available() else []):
            model.to(device)
            for count in [3,8,24]:
                batch=tensor_batch(tk.batch([request(count)]),slice(None),device)
                report[device+str(count)]=time_call(lambda:model(**batch),synchronize=torch.cuda.synchronize if device=='cuda' else None)
    write_json(a.output,report)
