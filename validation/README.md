# Validation Baseline

Run the honest baseline report with:

```bash
make validate
```

This writes:

- `results/validation/VALIDATION_REPORT.md`
- `results/validation/validation_report.json`

The repository fixtures are operational checks only. They do not contain
ophthalmologist labels, patient identifiers, or an untouched train/validation/
calibration/test split. Therefore the report marks clinical classification
metrics, calibration, patient-level leakage, external validation, and expert
validation as unavailable.

To evaluate a caller-supplied labeled ImageFolder dataset:

```bash
python validation/generate_report.py --data /path/to/dataset
```

The dataset must contain `grade_0` through `grade_4` directories. Keep the
final test directory untouched and do not use its results to tune thresholds.
