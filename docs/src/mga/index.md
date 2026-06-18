# Model-Generated Alternatives

Model-generated alternatives (MGA) explore solutions that remain close to the least-cost optimum while differing in design choices. This is useful because the least-cost model objective cannot represent every political, social, environmental, siting, resilience, and implementation concern that matters in real decisions.

IESA-Opt keeps MGA separate from the single-run workflow. The single-run pages build and solve one model. The MGA workspace is an additional exploration layer that is only activated through the **MGA** section of the local UI and the `/api/mga/*` endpoints.

## Why Hybrid ORACLE

The implemented workflow is a solver-backed hybrid ORACLE-style method. It combines exact near-optimal MGA solves with ORACLE-inspired refinement in a reduced design space:

1. Choose a system-cost slack, for example 5% above the least-cost objective.
2. Select a reduced exploratory design space, currently derived from workbook technology-sector groups.
3. Solve the original IESA-Opt LP to get the least-cost objective.
4. Add the near-optimality constraint `system_cost <= (1 + epsilon) * optimum_cost`.
5. Seed the design space with variable min/max directions and low-discrepancy parallel directions, each solved as a real LP over the original model constraints.
6. Estimate the largest remaining gap in normalized design space.
7. Add ORACLE-style closest-point LPs that target the largest estimated gaps.
8. Report alternatives, phase labels, diversity scores, slack use, solve status, and the estimated approximation certificate.

The reason for choosing this hybrid is practical: pure directional MGA is easy to parallelize but does not say whether important regions were missed. Pure ORACLE gives a convergence certificate, but its exact max-min metric requires a sequential MILP and repeated full model solves. The hybrid keeps the exact near-optimal LP formulation for every alternative, uses parallel directional seeds where possible, and adds ORACLE-style closest-point refinement so the UI can report an interpretable maximum unexplored design error.

## Implementation In IESA-Opt

The MGA implementation lives in the workflow helper file `src/workflows/mga/hybrid_oracle.jl`, and is only called from the UI server's MGA API routes. It does not add work to ordinary single runs.

The current implementation is solver-backed:

- Technology-sector groups are extracted from the selected workbook.
- The baseline IESA-Opt model is built and solved first.
- The baseline objective becomes the cost reference.
- Every alternative is solved with the original model constraints plus a system-cost cap.
- VMM and low-discrepancy seed directions replace the objective with a design-diversity objective.
- ORACLE refinement solves a closest-point LP using an `L_infinity` distance variable in the reduced design space.
- Results are displayed in the MGA progress/results pages with solver status, system cost, slack used, diversity, and convergence trace.

The alternative LP formulation is:

```text
max or min   w' z
s.t.         original IESA-Opt constraints
             system_cost <= (1 + epsilon) * optimum_cost
             z = Sx
```

The ORACLE closest-point refinement formulation is:

```text
min || z_trial - Sx ||_inf
s.t. original IESA-Opt constraints
     system_cost <= (1 + epsilon) * optimum_cost
     z = Sx
```

Here `x` is the full IESA-Opt decision vector and `Sx` is the reduced design projection, currently represented by technology-sector stock and investment aggregates. The formulation lives in `src/workflows/mga/hybrid_oracle.jl`, so the single-run and Scenario Space model builders remain unchanged.

## UI Workflow

Open the local UI and choose **MGA**.

- **Configure**: choose workbook, model shape, representative days, solver, solve method, cost slack, number of directions, workers, ORACLE tolerance, ORACLE iterations, and candidate count.
- **Preview design**: inspect the VMM seed directions, parallel seed directions, and ORACLE refinement directions.
- **Run MGA campaign**: solve the baseline LP, apply the cost cap, and solve the alternatives.
- **Progress**: follow baseline solve, seed solves, ORACLE closest-point solves, and result preparation. The progress page shows a live stage strip, a workers card with the alternative currently being solved, and a directions table that updates row-by-row as each LP terminates.
- **Results**: inspect the convergence trace, certificate cards, slack-versus-diversity scatter, alternatives table, and the investment-insight panel described below. Past campaigns are listed in the left sidebar and can be reloaded with a single click.

## Interpreting Results

The certificate reports:

- **Baseline cost**: least-cost objective from the original IESA-Opt LP.
- **Cost cap**: maximum allowed system cost for near-optimal alternatives.
- **Initial max error**: estimated largest normalized design-space gap before refinement.
- **Estimated max error**: estimated largest normalized design-space gap after the hybrid ORACLE design.
- **Target tolerance**: user-selected stopping target in normalized design units.
- **Design dimensions**: number of exploratory technology-sector groups.
- **Converged**: whether the estimated max error is below the target.

The alternatives table reports each direction's phase:

- `vmm`: variable min/max seed direction.
- `parallel-seed`: low-discrepancy direction that can be evaluated independently.
- `oracle-refine`: direction selected to reduce the largest estimated gap.

### Investments across alternatives

Every solved alternative also reports its full per-technology investment decisions (`techStock` and `cap_investments` summed over the solved periods). The UI aggregates these across the campaign and exposes the spread on the Results tab so that "near-optimal" becomes actionable rather than abstract:

- **Investment envelope chart**: a horizontal bar per technology showing the min&rarr;max range across all alternatives, color-coded by category (low-regret, high-volatility, optional, stable). A diamond marker shows the baseline (least-cost) level, so the chart immediately reveals whether MGA pushes a technology up, down, or both.
- **Low-regret investments**: top technologies built in *every* alternative with a tight relative spread (share = 100% and `(max - min) / mean <= 5%`). These are the capacities every near-optimal pathway agrees on, and therefore robust "no-regret" investments.
- **High-volatility investments**: top technologies whose installed level varies the most across alternatives (`(max - min) / max(mean, baseline) >= 40%`). These are the levers MGA finds &mdash; technologies the model can swap in or out without breaking the cost cap, and therefore the places where political, social, or implementation preferences can decide between alternatives at little or no cost penalty.
- **Optional / stable**: residual categories for technologies that are only built in some alternatives (optional) or built consistently with a moderate spread (stable).

The categorization thresholds (5% relative range for low-regret, 40% for high-volatility) are conservative defaults intended for screening; the full per-technology table includes baseline level, min, max, mean, standard deviation, relative range, and the share of alternatives that built the tech, so the same data can be reanalysed against alternative thresholds.

The `/api/mga/result/{id}` endpoint returns these aggregates as `investmentSpread` and the per-alternative detail as `results[].investments`, so external scripts can post-process the campaign without going through the UI.

## Method Context

Classical MGA solves repeated near-optimal optimization problems with alternative objectives. Most methods differ mainly in how the direction vector is chosen.

| Method | Main idea | Strength | Limitation |
| --- | --- | --- | --- |
| HSJ | Penalize variables used in previous solutions | Early and simple MGA heuristic | Sequential and no convergence guarantee |
| Random directional MGA | Use random direction vectors | Easy to parallelize; eventually explores vertices with unlimited iterations | No practical finite-iteration certificate |
| VMM | Minimize and maximize each exploratory variable | Good bounds for each variable; parallel | Misses combinations between variable extremes |
| ERG | Randomly assign -1, 0, or 1 weights | Simple sparse directions | No complete finite-iteration guarantee |
| SPORES | Spatially explicit practical alternatives with iterative scoring | Useful for spatially diverse alternatives | Mostly heuristic; convergence depends on variant |
| MAA | Build convex-hull region from discovered points | Region-based convergence idea | Convex hull volume becomes difficult beyond low dimensions |
| Manhattan MGA | Maximize distance from previous points | Direct diversity objective | Requires MILP around the full model |
| ORACLE | Maintain inner/outer approximations and refine largest certified gap | Interpretable convergence metric and coverage guarantee for convex models | Exact metric requires sequential MILP; best used in a reduced design space |

## References

- Brill, E. D. Jr. (1979). The use of optimization models in public-sector planning. *Management Science*.
- Brill, E. D. Jr., Chang, S.-Y., and Hopkins, L. D. (1982). Modeling to generate alternatives: The HSJ approach and an illustration using a problem in land use planning. *Management Science*.
- DeCarolis, J. F. (2011). Using modeling to generate alternatives (MGA) to expand our thinking on energy futures. *Energy Economics*.
- DeCarolis, J. F., Babaee, S., Li, B., and Kanungo, S. (2016). Modelling to generate alternatives with an energy system optimization model. *Environmental Modelling & Software*.
- Price, J. and Keppo, I. (2017). Modelling to generate alternatives: A technique to explore uncertainty in energy-environment-economy models. *Applied Energy*.
- Lombardi, F., Pickering, B., Colombo, E., and Pfenninger, S. (2020). Policy decision support for renewables deployment through spatially explicit practically optimal alternatives. *Joule*.
- Lombardi, F., Pickering, B., and Pfenninger, S. (2023). What is redundant and what is not? Computational trade-offs in modelling to generate alternatives for energy infrastructure deployment. *Applied Energy*.
- Neumann, F. and Brown, T. (2021). The near-optimal feasible space of a renewable power system model. *Electric Power Systems Research*.
- Pedersen, T. T., Victoria, M., Rasmussen, M. G., and Andresen, G. B. (2021). Modeling all alternative solutions for highly renewable energy systems. *Energy*.
- Grochowicz, A., van Greevenbroek, K., Benth, F. E., and Zeyringer, M. (2023). Intersecting near-optimal spaces: European power systems with more resilience to weather variability. *Energy Economics*.
- Lau, M., Patankar, N., and Jenkins, J. D. (2024). Measuring exploration: Review and systematic evaluation of modelling to generate alternatives methods in macro-energy systems planning models. *Environmental Research: Energy*.
- Turan, E. M., Moret, S., and Bardow, A. (2025). ORACLE: A rigorous metric and method to explore all near-optimal designs for energy systems. arXiv:2509.26452.