# Source Folder Layout

`src/entrypoints/` landing spot to run demos for to onboard researchers onto the repository. Also contains reusable functions each experiment's `run.py` in `experiments/`
- Note: It is helpful to use wandb during training

`src/architecture/` contains the source code (usually PyTorch) which contains the model architecture and model config dataclasses

`src/training_loop` contains reusable functions for training which are used by `experiments/`

`src/visualization` contains reusable functions for visualizing, pretty printing, and plotting at the end of each `experiments/`

- The main distinction between `src/` and `experiments/` is that `src/` should contain all the reusable functions that `experiments/` need (e.g. plotting, Wandb setup, and generic training loops). It is better practice to make `src/` more generic and duplicate code into `experiments/` for reproducibility.