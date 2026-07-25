# eGPU / USB4

This module is symptom-driven. Run **eGPU diagnostics** first; it is read-only
and separates results into USB4, devices, GPUs, kernel log, firmware, and render
offload tabs.

## Connection and authorization

Auto-authorization removes device approval friction. On hosts with IOMMU DMA
protection, the installed rule is gated on that protection attribute. On other
hosts it has a larger security tradeoff, which the confirmation screen reports.

Link quirks and PCI rescanning target enclosures that disconnect, fail to
enumerate, or appear only after a manual rescan.

## Runtime power management

Chain runtime-PM control can keep USB4 routers and their controller awake when a
device fails to return from low-power state. AMD GPU runtime options are broader
and can increase mobile power use; use them only when diagnostics and symptoms
match.

## Boot and driver paths

Boot ordering is for enclosures intended to be present from startup. The NVIDIA
GSP workaround applies only to the driver path described in its details and
refuses configurations where disabling GSP is unsupported.

For reliable testing, power the enclosure before connecting it, use the
machine's preferred USB4 port, and close applications and displays using the
external GPU before unplugging.
