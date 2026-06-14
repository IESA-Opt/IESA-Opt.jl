# Model-Generated Alternatives

Model-generated alternatives (MGA) help explore system configurations that are near-optimal but structurally different from the least-cost solution. Instead of asking only for the cheapest pathway, MGA asks: what other portfolios are possible if system cost may increase by a controlled amount?

## Method

The MGA workflow in the local UI uses an efficient directional design:

1. Define a system-cost slack, for example 5% above the least-cost objective.
2. Build low-correlation sector-weighted direction vectors from the technology groups in the input workbook.
3. Dispatch independent MGA directions in parallel, using the same worker-oriented campaign pattern as Scenario Space.
4. Compare alternatives by cost-slack use, diversity score, dominant technology group, and worker assignment.

The intended full optimization formulation is the standard MGA sequence: solve the least-cost model, add a cost-cap constraint, replace the objective with a diversity direction, and solve each direction independently. The current UI branch includes the parallel design harness and result browser, with the LP re-objectivization hook isolated for exact solver integration.

## UI Workflow

Open the local UI and choose **MGA**.

- Select the input workbook and campaign name.
- Set **System-cost slack (%)** to the tolerated cost increase.
- Set **Directions** to the number of alternatives to explore.
- Set **Parallel workers** and **Total CPU threads** according to the machine.
- Click **Preview design** to inspect the sector directions.
- Click **Run MGA campaign** to dispatch the direction set and view results.

Directions are independent, so MGA scales naturally across workers. For large studies, prefer more directions with modest per-worker thread counts rather than oversubscribing each solve.

## Interpreting Results

The MGA result chart plots system-cost slack used against the diversity score. A high diversity score indicates a direction that pushes harder away from the baseline sector mix. The dominant group identifies the sector with the largest absolute direction weight.

Use these outputs as a shortlist for deeper exact MGA solves, scenario review, or stakeholder discussion. Once the exact LP objective-switching hook is enabled, the same UI can display solved near-optimal alternatives rather than planned direction candidates.
