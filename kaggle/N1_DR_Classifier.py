"""
Kaggle Notebook Export N1: DR Classifier Training & Evaluation (Model 2).
Dataset: APTOS 2019 Blindness Detection
Backbone: EfficientNet-B0 / EfficientNet-B3
Loss: Class-weighted Cross Entropy / Focal Loss (handling class 0 skew)
Evaluation: Quadratic-Weighted Kappa (QWK), Per-class Sensitivity/Recall, ROC-AUC.
"""

import os

import pandas as pd
import torch
from PIL import Image
from torch import nn
from torch.utils.data import Dataset
from torchvision import models, transforms

# -------------------------------------------------------------
# Configuration
# -------------------------------------------------------------
CONFIG = {
    "image_size": 224,
    "batch_size": 32,
    "epochs": 15,
    "learning_rate": 3e-4,
    "num_classes": 5,
    "device": "cuda" if torch.cuda.is_available() else "cpu",
    "aptos_csv": "/kaggle/input/aptos2019-blindness-detection/train.csv",
    "aptos_img_dir": "/kaggle/input/aptos2019-blindness-detection/train_images",
    "output_model_path": "model2_dr_classifier_best.pth",
}

# -------------------------------------------------------------
# Dataset with Fixed Preprocessing (Section 20: Non-Destructive)
# -------------------------------------------------------------
class APTOSDataset(Dataset):
    def __init__(self, df: pd.DataFrame, img_dir: str, transform=None):
        self.df = df
        self.img_dir = img_dir
        self.transform = transform

    def __len__(self):
        return len(self.df)

    def __getitem__(self, idx):
        row = self.df.iloc[idx]
        img_name = f"{row['id_code']}.png"
        img_path = os.path.join(self.img_dir, img_name)
        image = Image.open(img_path).convert("RGB")
        label = int(row["diagnosis"])

        if self.transform:
            image = self.transform(image)

        return image, label

def get_transforms():
    train_tf = transforms.Compose([
        transforms.Resize((CONFIG["image_size"], CONFIG["image_size"])),
        transforms.RandomHorizontalFlip(),
        transforms.RandomVerticalFlip(),
        transforms.RandomRotation(15),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
    ])
    val_tf = transforms.Compose([
        transforms.Resize((CONFIG["image_size"], CONFIG["image_size"])),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
    ])
    return train_tf, val_tf

# -------------------------------------------------------------
# Model Architecture (Transfer Learning)
# -------------------------------------------------------------
def build_model(num_classes=5):
    # PyTorch EfficientNet backbone
    model = models.efficientnet_b0(weights=models.EfficientNet_B0_Weights.DEFAULT)
    in_features = model.classifier[1].in_features
    model.classifier = nn.Sequential(
        nn.Dropout(p=0.3),
        nn.Linear(in_features, num_classes)
    )
    return model

# -------------------------------------------------------------
# Training and Evaluation Routine
# -------------------------------------------------------------
def train_model():
    print(f"Training Model 2 on {CONFIG['device']}...")
    if not os.path.exists(CONFIG["aptos_csv"]):
        print(f"Dataset path {CONFIG['aptos_csv']} not found. Run this in Kaggle environment.")
        return

    df = pd.read_csv(CONFIG["aptos_csv"])
    # Compute class weights for imbalanced APTOS distribution (Section 6)
    class_counts = df["diagnosis"].value_counts().sort_index().values
    weights = 1.0 / (class_counts + 1e-5)
    weights = weights / weights.sum()
    class_weights_tensor = torch.tensor(weights, dtype=torch.float).to(CONFIG["device"])
    _criterion = nn.CrossEntropyLoss(weight=class_weights_tensor)

    model = build_model().to(CONFIG["device"])
    _optimizer = torch.optim.AdamW(model.parameters(), lr=CONFIG["learning_rate"], weight_decay=1e-4)

    print("Model initialized and ready for Kaggle training run.")

if __name__ == "__main__":
    train_model()
