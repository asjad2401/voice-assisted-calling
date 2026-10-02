"""Rebuild the bundled on-device models in assets/models/.

Run in a Python 3.11 virtualenv:

    pip install ultralytics onnx onnxslim onnx2tf tensorflow tf_keras \
        onnx_graphsurgeon sng4onnx ai-edge-litert onnxruntime psutil
    python tools/export_models.py --pkr path/to/best.pt

Why ONNX -> onnx2tf: recent Ultralytics releases route format='tflite'
through a LiteRT/torch path that can fail on some torch builds; going via
ONNX and onnx2tf produces the same graph reliably.

Outputs (float16 weights, float32 input/output, NHWC):
  coco_yolo11n.tflite          input 1x320x320x3 (RGB 0..1), output 1x84x2100
  pkr_currency_yolo11n.tflite  input 1x416x416x3 (RGB 0..1), output 1x11x3549
Box rows are cx, cy, w, h in model-input pixels; the rest are class scores.

The two embedders are downloaded as-is:
  image_embedder.tflite  MediaPipe MobileNetV3-small image embedder
                         (input 224x224 RGB 0..1, output 1024-d), Apache-2.0
  face_embedder.tflite   MobileFaceNet (input 112x112 RGB -1..1, output 192-d),
                         from the Apache-2.0 face_detection_tflite package.
"""
import argparse
import os
import shutil
import subprocess

import numpy as np
from ultralytics import YOLO

OUT = os.path.join(os.path.dirname(__file__), '..', 'assets', 'models')


def to_tflite(pt: str, imgsz: int, name: str) -> None:
    onnx_path = YOLO(pt).export(format='onnx', imgsz=imgsz, simplify=True, opset=17)
    work = f'tf_{name}'
    # onnx2tf wants a calibration sample; any data works for float export.
    sample = 'calibration_image_sample_data_20x128x128x3_float32.npy'
    if not os.path.exists(sample):
        np.save(sample, np.random.rand(20, 128, 128, 3).astype('float32'))
    subprocess.run(['onnx2tf', '-i', onnx_path, '-o', work, '-nuo', '-osd'], check=True)
    base = os.path.splitext(os.path.basename(onnx_path))[0]
    shutil.copy(os.path.join(work, f'{base}_float16.tflite'), os.path.join(OUT, f'{name}.tflite'))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--pkr', required=True, help='fine-tuned PKR YOLO11n checkpoint (best.pt)')
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    to_tflite(a.pkr, 416, 'pkr_currency_yolo11n')
    to_tflite('yolo11n.pt', 320, 'coco_yolo11n')
    print('done ->', os.path.abspath(OUT))
