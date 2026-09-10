# Minimal card rendering experiment

`minimal-card-template.patch` preserves the previously prepared body-only card
experiment. It is NOT applied to the default source or the native observer UI.
It changes only the embedded HTML body to a fixed heading and explicit test label;
resource URIs, MIME types, metadata and the normal tool catalog stay unchanged.
No JavaScript, CSS, assets, new endpoint, dependency or privilege is introduced.

Use a disposable source export of the exact consolidated revision when preparing
this experiment. Apply the patch there, leaving the canonical checkout unchanged,
then build and identify the resulting binary using the installed Swift toolchain.
Do not install an older diagnostic binary over newer core fixes. In particular,
the candidate must retain the Web catalog-refresh change from this revision.

Before a permitted normal-Chat trial, verify initialize/tools/list/resources/read
and the activity call against an empty disposable workspace. This tests delivery
only. Installing the exact reviewed artifact and any restart still require the
owner's approval and preservation of active work/retained recovery state.

The experiment asks one question: does the host render a minimal HTML body with
the same integration metadata? If it still returns the same missing-asset error,
restore the approved full-template artifact and stop varying HTML on that basis.
A visible test heading alone is NOT a finished activity card. Keep the full UI
source, the native observer and the newer core changes intact.

Record live identities and private deployment evidence outside this repository.
