# Model 1 Quality Dataset: Labeling Criteria

This document details the objective criteria for annotating retinal fundus images into **Good**, **Borderline**, and **Bad** classes for Model 1 training and validation.

---

## 1. Quality Dimensions

| Dimension | Measure | Good Criteria | Borderline Criteria | Bad Criteria |
|---|---|---|---|---|
| **Sharpness / Blur** | Laplacian Variance / Retinal vessel edge acuity | Retinal vessels & fine arcade branches sharply in focus across >80% of macula/disc | Primary arcades visible; peripheral or macular fine branches softened | Primary arcades smeared; optic disc / macula cannot be clearly demarcated |
| **Illumination** | Mean luminance & pixel saturation | Balanced exposure across retinal field; neither underexposed nor clipped | Mildly dark or localized glare; major structures discernible | Severe shadow, total underexposure, or massive flash reflection obscuring center |
| **Contrast** | Vessel-to-background contrast | Distinct contrast between vessel lumen and background fundus | Low contrast; requires effort to trace secondary vessel branches | Flat histogram; vessels indistinguishable from background |
| **Field of View (FOV)** | Retinal circle visibility & centering | Full 45°/50° field with both optic disc and macula contained | Partial clipping of peripheral retina; disc or macula near edge | Severe cutoff; disc and macula not captured or outside field |
| **Artifacts** | Dust, eyelashes, lens smudges | Minimal or absent; outside the central 1-disc-diameter of macula | Eyelash shadows or lens halos present in peripheral field | Dense eyelash/cataract/lens smudge completely covering macula |

---

## 2. Practical Data Generation (Section 11)

Because public quality datasets (such as EyePACS quality subsets or DeepDRiD) may have limited sample sizes, the plan specifies:
1. **Synthetic Degradation of Good Images:**
   - Gaussian blur ($\sigma \in [2.0, 7.0]$) to simulate defocus/motion blur.
   - Illumination scaling ($\times 0.2$ to $\times 0.6$ for underexposure, $> 1.4$ for glare).
   - Synthetic vignetting and peripheral shadowing.
2. **Real-world Edge Captures:**
   - Retaining real-world blurry or dark captures from public collections.
