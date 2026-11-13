"""
Kaggle Notebook Export N3: Model 2 Grad-CAM Explainability & Qualitative Sanity Checks.
Scope:
- Final convolutional layer gradient visualization
- Heatmap overlay generation over original pixel data
- Qualitative sanity check against IDRiD lesion annotations (microaneurysms, hemorrhages, hard/soft exudates)
- Stating explicit claim boundary per Section 8.
"""

import numpy as np

EXPLAINABILITY_CLAIM_BOUNDARY = (
    "CLAIM BOUNDARY: Grad-CAM highlights which spatial regions most influenced "
    "the network's prediction. It does not provide pixel-level lesion segmentation "
    "and does not prove diagnostic pathology on its own."
)

def generate_gradcam_pytorch(model, input_tensor, target_layer):
    """Generates standard Grad-CAM activation heatmap from PyTorch model."""
    activations = []
    gradients = []

    def forward_hook(module, input, output):
        activations.append(output)

    def backward_hook(module, grad_in, grad_out):
        gradients.append(grad_out[0])

    handle_fwd = target_layer.register_forward_hook(forward_hook)
    handle_bwd = target_layer.register_full_backward_hook(backward_hook)

    # Forward pass
    output = model(input_tensor)
    pred_idx = output.argmax(dim=1).item()

    # Backward pass on predicted class
    model.zero_grad()
    score = output[0, pred_idx]
    score.backward()

    handle_fwd.remove()
    handle_bwd.remove()

    grad = gradients[0].cpu().data.numpy()[0]
    act = activations[0].cpu().data.numpy()[0]

    # Global average pooling on gradients
    weights = np.mean(grad, axis=(1, 2))
    cam = np.zeros(act.shape[1:], dtype=np.float32)

    for i, w in enumerate(weights):
        cam += w * act[i, :, :]

    cam = np.maximum(cam, 0)
    if np.max(cam) > 0:
        cam = cam / np.max(cam)

    return cam, pred_idx

if __name__ == "__main__":
    print(EXPLAINABILITY_CLAIM_BOUNDARY)
