# SAGIN remote robotics manuscript

Open `0_main.pdf` for the compiled green review and `0_main.tex` for the editable
project. The supplied figure is in `Images/image.png`.

The supplied `0_main.tex`, `1_Intro.tex`, `2_System.tex`, `3_Method.tex` and
`library.bib` are preserved byte for byte under `original/`. The working copies
contain only insertions marked `BEGIN PANAMA ADDITIONS` / `END PANAMA ADDITIONS`.
Existing manuscript text, equations, comments and yellow highlights are retained.
Automatic equation numbering follows the added equations.

## Added material

- Introduction: scope of the communication extension.
- System model: message generation/arrival times, receiver caches, source ages,
  UAV-mediated peer communication and physical-state separation.
- Method: cached absolute A* guidance, asymmetric intention/priority observations,
  received experience subsets, off-policy learner continuation, complete atomic
  model deployments, model age/version lag and pseudocode.
- Main file: green review markup, bibliography coloring and font/Unicode
  compatibility for compilation.
- Bibliography: a PANAMA manuscript citation without invented publication metadata.

Delays are symbolic transport inputs. No random delay schedule, LEO delay formula
or simulation results have been inserted. Nominal learning parameters in the
method follow PANAMA, as requested. The fast-pilot settings in this repository
and simulator code were not changed; the manuscript does not assert that those
pilots used the nominal parameters stated here.

`4_Simulations.tex` was referenced by the supplied main file but was not supplied.
An empty include is provided solely to compile the project. Replace it with your
own simulation section when available.

## Compile and reuse

Compile from this directory using a normal LaTeX installation:

```sh
latexmk -pdf -interaction=nonstopmode 0_main.tex
```

Or use Tectonic:

```sh
tectonic --untrusted 0_main.tex
```

For Overleaf, upload the working `.tex` files, `library.bib` and the `Images`
directory, and select `0_main.tex` as the main document. To remove the green
review color while retaining the additions, set `panamaaddition` to
`{RGB}{0,0,0}` in the main-file preamble.
