## Simulation results (40 seeds per configuration)

### A. Pacing strategy

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | baseline | demand ×1.15 | day-4 shock 20% | last-12h shock 30% | demand ×0.9 |
|---|---|---|---|---|---|
| uniform | 100.00 / 100.00 | 98.73 / 98.00 | 99.92 / 99.73 | 98.03 / 97.78 | 88.04 / 86.88 |
| adaptive, no level factor | 100.00 / 100.00 | 100.00 / 100.00 | 100.00 / 100.00 | 97.62 / 97.31 | 92.10 / 89.98 |
| adaptive (default) | 100.00 / 100.00 | 100.00 / 100.00 | 100.00 / 100.00 | 99.32 / 99.16 | 92.10 / 89.98 |
| uniform, no margin | 97.93 / 97.61 | 92.06 / 91.26 | 94.69 / 93.90 | 93.05 / 92.71 | 82.48 / 81.54 |
| adaptive, no margin | 100.00 / 100.00 | 98.36 / 97.84 | 99.15 / 98.64 | 96.19 / 95.96 | 89.60 / 88.25 |

### B. Planning margin — spend

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | baseline | demand ×1.15 | last-12h shock 30% |
|---|---|---|---|
| none (0 h, 0) | 100.00 / 100.00 | 98.36 / 97.84 | 96.19 / 95.96 |
| buffer 6 h | 100.00 / 100.00 | 99.88 / 99.46 | 98.14 / 97.96 |
| 1 h + haircut 0.05 | 100.00 / 100.00 | 99.91 / 99.61 | 97.26 / 97.04 |
| 1 h + haircut 0.1 | 100.00 / 100.00 | 100.00 / 100.00 | 98.05 / 97.84 |
| 1 h + haircut 0.2 (default) | 100.00 / 100.00 | 100.00 / 100.00 | 99.32 / 99.16 |
| 1 h + haircut 0.3 | 100.00 / 100.00 | 100.00 / 100.00 | 100.00 / 99.99 |

### B'. Planning margin — idle tail

_cell: hours before T at which 99.9 % of B was spent (– = never); 40 runs per cell_

| variant | baseline | demand ×1.15 | last-12h shock 30% |
|---|---|---|---|
| none (0 h, 0) | 0.6 | – | – |
| buffer 6 h | 6.3 | 1.2 | – |
| 1 h + haircut 0.05 | 1.8 | 1.0 | – |
| 1 h + haircut 0.1 | 2.1 | 2.0 | – |
| 1 h + haircut 0.2 (default) | 2.8 | 2.7 | – |
| 1 h + haircut 0.3 | 3.8 | 3.7 | 1.9 |

### C. Grant duration τ

_40 runs per row_

| variant | spend mean % | min % | runs over B | max over (‰ B) | grants/min | util % | Ŝ err ‰ | Y err ‰ | done before T (h) | alert runs |
|---|---|---|---|---|---|---|---|---|---|---|
| τmax = 15 min | 100.000 | 100.000 | 0 | 0.000 | 4.55 | 82.9 | 0.099 | 2.976 | 2.7 | 0 |
| τmax = 60 min (default) | 100.000 | 100.000 | 0 | 0.000 | 2.36 | 89.9 | 0.099 | 2.976 | 2.8 | 0 |
| τmax = 240 min | 100.000 | 100.000 | 0 | 0.000 | 2.28 | 88.7 | 0.099 | 2.976 | 2.8 | 0 |
| τ = 240 fixed | 100.000 | 100.000 | 0 | 0.000 | 0.32 | 70.4 | 0.099 | 2.976 | 5.3 | 0 |
| volatile, τmax = 15 | 100.000 | 100.000 | 0 | 0.000 | 4.57 | 76.4 | 0.099 | 2.976 | 2.5 | 0 |
| volatile, τmax = 60 | 100.000 | 100.000 | 0 | 0.000 | 2.56 | 65.9 | 0.099 | 2.976 | 2.5 | 0 |
| volatile, τ = 240 fixed | 100.000 | 100.000 | 0 | 0.000 | 0.55 | 33.5 | 0.099 | 2.976 | 6.6 | 0 |

### D. Client behaviour (re-grant, return)

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | volatile, τ=240 | 5 volatile, τ=240 | volatile, demand ×1.2 | last-12h shock 30% |
|---|---|---|---|---|
| re-grant + partial return (default) | 100.00 / 100.00 | 100.00 / 100.00 | 99.85 / 98.08 | 99.32 / 99.16 |
| no partial return | 100.00 / 100.00 | 100.00 / 100.00 | 99.85 / 98.08 | 99.32 / 99.16 |
| no re-grant | 96.23 / 93.62 | 93.67 / 86.42 | 98.55 / 95.36 | 99.31 / 99.15 |
| no return at all | 99.99 / 99.94 | 99.74 / 98.35 | 99.85 / 98.08 | 99.32 / 99.16 |

### E. Exposure accounting

_cell: mean % / min % of B spent; 40 runs per cell_

| variant | baseline | volatile, τ=240 | 5 volatile, τ=240 |
|---|---|---|---|
| reported counters (default) | 100.00 / 100.00 | 100.00 / 100.00 | 100.00 / 100.00 |
| full grant amounts | 100.00 / 100.00 | 99.95 / 99.87 | 99.94 / 99.76 |

### F. Delay compensation (nowcast)

_40 runs per row_

| variant | spend mean % | min % | runs over B | max over (‰ B) | grants/min | util % | Ŝ err ‰ | Y err ‰ | done before T (h) | alert runs |
|---|---|---|---|---|---|---|---|---|---|---|
| D = 30, nowcast | 100.000 | 100.000 | 0 | 0.000 | 2.36 | 89.9 | 0.099 | 2.976 | 2.8 | 0 |
| D = 30, pace on Y | 100.000 | 100.000 | 0 | 0.000 | 2.28 | 90.0 | 2.976 | 2.976 | 3.8 | 0 |
| D = 120, nowcast | 99.998 | 99.998 | 0 | 0.000 | 2.36 | 89.9 | 0.100 | 11.903 | 2.8 | 0 |
| D = 120, pace on Y | 100.000 | 100.000 | 0 | 0.000 | 1.94 | 90.3 | 11.905 | 11.905 | 7.6 | 0 |
| D = 240, nowcast | 99.991 | 99.991 | 0 | 0.000 | 2.35 | 89.9 | 0.103 | 23.793 | 2.8 | 0 |
| D = 240, pace on Y | 100.000 | 100.000 | 0 | 0.000 | 1.73 | 90.6 | 23.809 | 23.809 | 9.9 | 0 |
| D = 240, last-12h shock, nowcast | 99.316 | 99.165 | 0 | 0.000 | 2.54 | 89.1 | 0.103 | 23.603 | – | 40 |
| D = 240, last-12h shock, pace on Y | 100.000 | 99.999 | 0 | 0.000 | 1.96 | 90.4 | 23.809 | 23.809 | 7.2 | 0 |

### G. Safety assumptions

_40 runs per row_

| variant | spend mean % | min % | runs over B | max over (‰ B) | grants/min | util % | Ŝ err ‰ | Y err ‰ | done before T (h) | alert runs |
|---|---|---|---|---|---|---|---|---|---|---|
| D = 30 ± 15, D_max = 45 (correct) | 100.000 | 99.999 | 0 | 0.000 | 2.35 | 89.9 | 0.475 | 3.343 | 2.9 | 0 |
| D = 30 ± 15, D_max = 30 (too small) | 100.006 | 100.003 | 40 | 0.087 | 2.36 | 89.9 | 0.475 | 3.343 | 2.9 | 0 |
| β = 1.02, β_max = 1.06 (correct) | 100.000 | 100.000 | 0 | 0.000 | 2.36 | 89.9 | 0.099 | 2.976 | 2.8 | 0 |
| β = 1.08, β_max = 1.06 (too small) | 100.000 | 100.000 | 40 | 0.004 | 2.28 | 90.2 | 0.099 | 2.976 | 3.2 | 0 |
| noise cv = 1.5 | 100.000 | 100.000 | 0 | 0.000 | 2.47 | 83.9 | 0.099 | 2.976 | 2.8 | 0 |
