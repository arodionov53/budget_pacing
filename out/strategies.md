## Simulation results (40 seeds per configuration)

### A. Pacing strategy

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | baseline | demand ×1.15 | day-4 shock 20% | last-12h shock 30% | demand ×0.9 |
|---|---|---|---|---|---|
| uniform | 100.00 / 100.00 | 98.22 / 97.47 | 99.72 / 99.46 | 97.71 / 97.45 | 87.61 / 86.48 |
| adaptive, no level factor | 100.00 / 100.00 | 100.00 / 100.00 | 100.00 / 100.00 | 97.37 / 97.05 | 92.02 / 89.93 |
| adaptive (default) | 100.00 / 100.00 | 100.00 / 100.00 | 100.00 / 100.00 | 99.14 / 98.98 | 92.02 / 89.94 |
| uniform, no margin | 97.59 / 97.23 | 91.47 / 90.69 | 94.11 / 93.31 | 92.57 / 92.21 | 81.98 / 81.06 |
| adaptive, no margin | 100.00 / 100.00 | 97.74 / 97.22 | 98.56 / 97.98 | 95.82 / 95.60 | 89.21 / 87.96 |

### B. Planning margin — spend

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | baseline | demand ×1.15 | last-12h shock 30% |
|---|---|---|---|
| none (0 h, 0) | 100.00 / 100.00 | 97.74 / 97.22 | 95.82 / 95.60 |
| buffer 6 h | 100.00 / 100.00 | 99.39 / 98.84 | 97.85 / 97.66 |
| 1 h + haircut 0.05 | 100.00 / 100.00 | 99.49 / 99.02 | 96.94 / 96.72 |
| 1 h + haircut 0.1 | 100.00 / 100.00 | 100.00 / 100.00 | 97.77 / 97.56 |
| 1 h + haircut 0.2 (default) | 100.00 / 100.00 | 100.00 / 100.00 | 99.14 / 98.98 |
| 1 h + haircut 0.3 | 100.00 / 100.00 | 100.00 / 100.00 | 99.99 / 99.92 |

### B'. Planning margin — idle tail

_cell: hours before T at which 99.9 % of B was spent (– = never); 40 runs per cell_

| variant | baseline | demand ×1.15 | last-12h shock 30% |
|---|---|---|---|
| none (0 h, 0) | 0.6 | – | – |
| buffer 6 h | 6.2 | 0.6 | – |
| 1 h + haircut 0.05 | 1.7 | 0.4 | – |
| 1 h + haircut 0.1 | 2.0 | 1.9 | – |
| 1 h + haircut 0.2 (default) | 2.6 | 2.5 | – |
| 1 h + haircut 0.3 | 3.6 | 3.5 | 1.2 |

### C. Grant duration τ

_40 runs per row_

| variant | spend mean % | min % | runs over B | max over (‰ B) | grants/min | util % | Ŝ err ‰ | Y err ‰ | done before T (h) | alert runs |
|---|---|---|---|---|---|---|---|---|---|---|
| τmax = 15 min | 100.000 | 100.000 | 0 | 0.000 | 4.56 | 82.9 | 0.099 | 2.976 | 2.6 | 0 |
| τmax = 60 min (default) | 100.000 | 100.000 | 0 | 0.000 | 2.38 | 89.9 | 0.099 | 2.976 | 2.6 | 0 |
| τmax = 240 min | 100.000 | 100.000 | 0 | 0.000 | 2.30 | 88.6 | 0.099 | 2.976 | 2.6 | 0 |
| τ = 240 fixed | 100.000 | 100.000 | 0 | 0.000 | 0.32 | 70.5 | 0.099 | 2.976 | 5.1 | 0 |
| volatile, τmax = 15 | 100.000 | 100.000 | 0 | 0.000 | 4.59 | 76.4 | 0.099 | 2.976 | 2.4 | 0 |
| volatile, τmax = 60 | 100.000 | 100.000 | 0 | 0.000 | 2.59 | 66.0 | 0.099 | 2.976 | 2.4 | 0 |
| volatile, τ = 240 fixed | 100.000 | 100.000 | 0 | 0.000 | 0.55 | 33.6 | 0.099 | 2.976 | 6.3 | 0 |

### D. Client behaviour (re-grant, return)

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | volatile, τ=240 | 5 volatile, τ=240 | volatile, demand ×1.2 | last-12h shock 30% |
|---|---|---|---|---|
| re-grant + partial return (default) | 100.00 / 100.00 | 100.00 / 99.98 | 99.66 / 97.61 | 99.14 / 98.98 |
| no partial return | 100.00 / 100.00 | 100.00 / 99.89 | 99.66 / 97.61 | 99.14 / 98.98 |
| no re-grant | 95.71 / 93.30 | 93.20 / 85.98 | 98.16 / 94.92 | 99.13 / 98.97 |
| no return at all | 99.98 / 99.95 | 99.74 / 98.67 | 99.66 / 97.61 | 99.14 / 98.98 |

### E. Exposure accounting

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | baseline | volatile, τ=240 | 5 volatile, τ=240 |
|---|---|---|---|
| reported counters (default) | 100.00 / 100.00 | 100.00 / 100.00 | 100.00 / 99.98 |
| full grant amounts | 100.00 / 100.00 | 99.94 / 99.87 | 99.93 / 99.72 |

### F. Delay compensation (nowcast)

_40 runs per row_

| variant | spend mean % | min % | runs over B | max over (‰ B) | grants/min | util % | Ŝ err ‰ | Y err ‰ | done before T (h) | alert runs |
|---|---|---|---|---|---|---|---|---|---|---|
| D = 30, nowcast | 100.000 | 100.000 | 0 | 0.000 | 2.38 | 89.9 | 0.099 | 2.976 | 2.6 | 0 |
| D = 30, pace on Y | 100.000 | 100.000 | 0 | 0.000 | 2.30 | 90.0 | 2.976 | 2.976 | 3.7 | 0 |
| D = 120, nowcast | 99.998 | 99.998 | 0 | 0.000 | 2.38 | 89.9 | 0.100 | 11.903 | 2.6 | 0 |
| D = 120, pace on Y | 100.000 | 100.000 | 0 | 0.000 | 1.95 | 90.3 | 11.905 | 11.905 | 7.4 | 0 |
| D = 240, nowcast | 99.990 | 99.989 | 0 | 0.000 | 2.37 | 89.9 | 0.103 | 23.791 | 2.6 | 0 |
| D = 240, pace on Y | 100.000 | 100.000 | 0 | 0.000 | 1.74 | 90.6 | 23.809 | 23.809 | 9.7 | 0 |
| D = 240, last-12h shock, nowcast | 99.143 | 98.981 | 0 | 0.000 | 2.54 | 89.0 | 0.103 | 23.561 | – | 40 |
| D = 240, last-12h shock, pace on Y | 99.999 | 99.999 | 0 | 0.000 | 2.00 | 90.4 | 23.809 | 23.809 | 6.9 | 0 |

### G. Safety assumptions

_40 runs per row_

| variant | spend mean % | min % | runs over B | max over (‰ B) | grants/min | util % | Ŝ err ‰ | Y err ‰ | done before T (h) | alert runs |
|---|---|---|---|---|---|---|---|---|---|---|
| D = 30 ± 15, D_max = 45 (correct) | 100.000 | 99.999 | 0 | 0.000 | 2.37 | 89.8 | 0.475 | 3.343 | 2.7 | 0 |
| D = 30 ± 15, D_max = 30 (too small) | 100.007 | 100.004 | 40 | 0.101 | 2.37 | 89.8 | 0.475 | 3.343 | 2.7 | 0 |
| β = 1.02, β_max = 1.06 (correct) | 100.000 | 100.000 | 0 | 0.000 | 2.38 | 89.9 | 0.099 | 2.976 | 2.6 | 0 |
| β = 1.08, β_max = 1.06 (too small) | 100.001 | 100.000 | 40 | 0.006 | 2.36 | 90.1 | 0.099 | 2.976 | 2.6 | 0 |
| noise cv = 1.5 | 100.000 | 100.000 | 0 | 0.000 | 2.49 | 83.9 | 0.099 | 2.976 | 2.6 | 0 |
