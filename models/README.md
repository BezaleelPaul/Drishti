# Drishti AI Models

Production deep learning and quantization weights for the clinical diabetic retinopathy diagnostic pipeline.

- `final_model.keras`: EfficientNet-B0 backbone trained on APTOS-2019 and EyePACS datasets.
- `efficientnet_b0_regression_512px.onnx`: ONNX runtime export for edge deployment.
- `dr_efficientnet_b0_tuned_fp32.tflite`: FP32 TensorFlow Lite runtime model.
- `dr_efficientnet_b0_tuned_int8.tflite`: Quantized INT8 model for low-power mobile inference.
- `clinical_scorecard.json`: Evaluation metrics across sensitivity, specificity, and quadratic weighted kappa.
