# SBCL & Quicklisp — Research Notes

## 1. Overview

### SBCL (Steel Bank Common Lisp)

- A high-performance, open-source **Common Lisp compiler and runtime**, forked from CMUCL by William Newman in December 1999.
- License: mostly **public domain**, with some BSD/MIT-licensed parts — very permissive.
- Mostly-conforming implementation of the **ANSI Common Lisp standard**.
- Platforms: Linux, macOS, Windows, FreeBSD/NetBSD/OpenBSD, DragonFly BSD, Solaris.
- **Compiler-only design**: SBCL has no traditional interpreter in normal operation. Even `eval` works by wrapping the form in a lambda, calling `compile` on it, and `funcall`ing the resulting compiled function object. This means everything you type at the REPL is natively compiled — which is central to how hot-patching works (see §3).
- Ships with an interactive environment including a **debugger, statistical profiler (sb-sprof), code coverage tool, tracer, inspector**, and many `sb-*` extension packages (sb-ext, sb-thread, sb-bsd-sockets, sb-introspect, sb-cltl2, ...).
- Key operational features:
  - `save-lisp-and-die` — dump the current image as a standalone executable (how most Lisp servers are deployed).
  - Strong native-code compiler (derived from CMUCL's Python compiler) with type inference driven by declarations.
- References:
  - https://www.sbcl.org/
  - https://sbcl.org/manual/ (SBCL User Manual — esp. the "Overview of SBCL, how it works and where it came from")
  - https://en.wikipedia.org/wiki/Steel_Bank_Common_Lisp

### Quicklisp

- The de-facto **library manager for Common Lisp**, by Zach Beane (Xach). Works with SBCL (and other implementations).
- Knows about **1500+ libraries** with dependency metadata; can download, compile and load a library and all its transitive dependencies with one command.
- Install once:

  ```
  curl -O https://beta.quicklisp.org/quicklisp.lisp
  sbcl --load quicklisp.lisp
  ;; then, in the REPL:
  (quicklisp-quickstart:install)
  (ql:add-to-init-file)   ; makes SBCL load quicklisp from ~/.sbclrc
  ```

- Main commands:
  | Command | Purpose |
  |---|---|
  | `(ql:quickload "alexandria")` | Download + compile + load a system (and its deps). Idempotent. |
  | `(ql:quickload '("alexandria" "bordeaux-threads"))` | Load several at once |
  | `(ql:system-apropos "postgres")` | Search for systems |
  | `(ql:where-is-system "alexandria")` | Local path of a system |
  | `(ql:update-all-dists)` | Upgrade everything to the latest dist |
  | `(ql:update-dist "quicklisp")` | Pull the newest dist metadata |
  | `(ql:uninstall "foo")` / `(ql:uninstall-dist "foo")` | Remove |
- **Dists**: a *dist* is a versioned snapshot of a set of projects with metadata. The default `quicklisp` dist is released roughly **monthly**, with the guarantee that all systems in it build together. You can pin, mix, or create **private dists** (e.g. via `distman` or `quickdist`) for internal code.
- **Division of labor**: Quicklisp ≈ apt (downloads archives, resolves versions); **ASDF** ≈ make (actually compiles and loads systems). Quicklisp finds and fetches; ASDF defines what a "system" is (`defsystem` in a `.asd` file) and builds it.
- Local projects: symlink or copy the project into `~/quicklisp/local-projects/` and `(ql:quickload "my-project")` just works.
- References:
  - https://www.quicklisp.org/beta/
  - https://quicklisp.org/beta/faq.html
  - https://cl-library-docs.github.io/common-lisp-libraries/quicklisp/

### ASDF (the layer underneath)

- "Another System Definition Facility", bundled with SBCL (`(require :asdf)`).
- Systems are declared in `.asd` files with `asdf:defsystem`, listing components (files), dependencies (`:depends-on`), and load order.
- `(asdf:load-system :foo)` compiles out-of-date files and loads them (per-file FASLs cached in `~/.cache/common-lisp/`).
- Note: ASDF has **no true unload** operation (see §4).

## 2. Package management in depth

Two different meanings of "package" in this world — don't conflate them:

1. **CL packages** (`defpackage`) — namespaces for *symbols*, part of the ANSI standard. Live and mutable at runtime (`export`, `intern`, `unintern`, `rename-package`...).
2. **Systems / libraries** (`defsystem`, Quicklisp) — units of *code distribution*, like npm packages.

Workflow for managing libraries:

- **Search**: `(ql:system-apropos "json")`
- **Load**: `(ql:quickload "cl-json")` — downloads source tarballs from the dist server, stores under `~/quicklisp/dists/quicklisp/software/`, then hands off to ASDF to compile/load.
- **Pinning / reproducibility**: dists are versioned (`quicklisp 2024-10-12`, ...). Team workflows typically pin a dist version, or use tools like **Qlot** (per-project library pinning, like a lockfile) or **CLPM** (a newer, lockfile-based alternative package manager).
- **Upgrading**: `(ql:update-dist "quicklisp")` then `(ql:update-all-dists)`. Note this does *not* automatically reload already-loaded libraries in a running image — you generally restart the image or reload systems manually (see §3).
- **Private code**: `~/quicklisp/local-projects/`, private dists via `quickdist`, or just ASDF source-registry configuration (`~/.config/common-lisp/source-registry.conf.d/`).

## 3. Hot loading / online modification of code

This is where SBCL/Common Lisp fundamentally differs from most runtimes. Redefinition while running is a **first-class, standard, everyday operation**, not a hack.

### 3.1 Redefining a function at runtime

Just evaluate a new `defun` (or `C-c C-c` the form in SLIME/Sly):

```lisp
(defun price (x) (* x 2))      ; original
;; ... server is running, price is being called ...
(defun price (x) (* x 3))      ; redefined, live
```

Mechanics:

- `defun` compiles the lambda to a **new native-code function object** and installs it as the *symbol-function* of `price` (under SBCL package locks permitting — see §5).
- A name is an indirection: callers go through the symbol, so **new calls pick up the new function immediately**.
- This is *not* self-modifying code. Stack frames currently executing the old code hold a direct reference to the old function object, so it stays alive (GC-visible) and **runs to completion**; only subsequent calls use the new definition. No dispatch-table overhead, no NOP-sled patching — the indirection is the symbol/function-name slot.
- Caveat: if you passed `#'price` around (as a callback, handler, etc.), you captured the *old function object*. Re-fetch with `(symbol-function 'price)` or call by name (`(funcall 'price ...)`) to get dynamic lookup.

### 3.2 The live-reload development loop

The canonical setup is **Emacs + SLIME** (or Sly), talking to a **Swank server** embedded in the running Lisp:

```lisp
(ql:quickload "swank")
(swank:create-server :port 4005 :dont-close t)
```

Then connect from any editor (`M-x slime-connect`) and recompile/redefine individual forms, files, or whole systems in the live process. This works against **long-running production servers** too:

- Deploy via `sbcl --load app.lisp` (drops you into the REPL with the app running in its own threads) or ship a `save-lisp-and-die` binary that starts a Swank server on a port (optionally tunneled over SSH).
- You can then inspect state, evaluate expressions in the live image, redefine functions/macros/classes, re-run tests — all without restarting.

### 3.3 Reloading whole systems

- `(asdf:load-system :my-app :force t)` recompiles+reloads all files of a system.
- `(ql:quickload "my-app")` again after editing also works (ASDF skips up-to-date FASLs).
- **Reload order matters**: if a macro changed, code that *uses* the macro must be recompiled to see the new expansion — a common live-patching gotcha.
- The **condition system** makes errors survivable: an error drops you into the debugger with restarts (e.g. `ABORT`, `RETRY`), the server keeps running, you fix and recompile the offending form, then invoke a restart to continue from where it failed. This is the famous "debug a spacecraft from Earth" workflow (NASA DS1 story).

### 3.4 CLOS: redefining classes with live instances

CLOS goes far beyond function patching:

- Evaluating a new `defclass` **modifies the existing class object in place** (CLHS 4.3.6 "Redefining Classes"). No recompilation of client code needed.
- Existing instances are updated **lazily**: SBCL/PCL uses the *wrapper cache* mechanism (`src/pcl/wrapper.lisp`) — an obsolete wrapper flags instances for update; `make-instances-obsolete` triggers the update machinery, and the actual migration happens on next slot access (or via `change-class`).
- Slot migration is customizable via methods on:
  - `update-instance-for-redefined-class` — called for instances of a redefined class; you write methods to carry over/compute slot values.
  - `update-instance-for-different-class` — after `change-class` transforms an instance into a different class.
- So you can add/remove/rename slots of a class **while thousands of live instances exist** in a running server, and control exactly how their state migrates.
- Generic functions are similarly live: `defmethod` replaces methods, `remove-method` deletes them, and method dispatch caches are invalidated automatically (same wrapper machinery).

## 4. Unloading / removing code

Common Lisp has **no "module unload"** in the Java/Python sense — the image is a single heap and anything may hold references to anything. Unloading is done *piecewise*:

- **Functions**: `(fmakunbound 'foo)` removes the function binding of the symbol. Old function objects are GC'd once no references remain (stack frames, data structures, symbol-function slots).
- **Variables/constants**: `(makunbound 'foo)` removes the value binding.
- **Symbols**: `(unintern 'foo)` removes the symbol from its package; if nothing else references it, it gets GC'd.
- **Packages**: `(delete-package :my-package)` (fails if the package is still used by others).
- **Classes**: `setf (find-class 'foo) nil` removes the class name binding; methods defined on it may need explicit `remove-method` cleanup. Redefinition (§3.4) is usually preferable to removal.
- **Whole systems**: there is no standard `unload-system`. Workarounds:
  - ASDF only has `load-system`; unloading requires manually fmakunbound/delete-package'ing everything (brittle, rarely done).
  - Libraries like **trivial-garbage**/application conventions aside, the *practical* answer in long-running servers is: **redefine, don't unload**. New definitions replace old ones; orphans get GC'd. Memory/image bloat from stale code is usually negligible compared to the value of a live session.
- Old compiled code objects are ordinary heap objects: once unreferenced (after `fmakunbound` etc.), SBCL's garbage collector reclaims them — including their native code.

## 5. Practical caveats for hot-patching SBCL

- **Package locks**: SBCL locks its own implementation packages (`CL`, `SB-EXT`, ...) against redefinition by default (`sb-ext:package-locked-p`). Unlock with `(sb-ext:unlock-package :cl)` if you really must patch internals.
- **Inlining / optimize declarations**: code compiled with high `speed` and inline calls (`declaim (inline f)` or SBCL's cross-module inlining) may have baked the *old* definition into callers. Either avoid inlining for hot-patchable seams, or recompile callers too (`(declaim (notinline f))` in dev builds is a common policy).
- **Captured function objects** (`#'f` stored in hash tables, hooks, handler lists) keep the old version — store symbols and `funcall` by name if late binding is wanted.
- **Macros** must have their call sites recompiled after redefinition.
- **Threads**: redefinition is safe per se, but be careful changing code while threads are mid-flight; there is no global "safe point" coordination — use your own locks if the change is not atomic from the app's point of view.
- **Constants** redefined with `defconstant` are technically undefined behavior to redefine; use `defparameter`/`sb-ext:defglobal` for values that may change.
- **Structure types** (`defstruct`) do *not* get the CLOS lazy-update machinery — redefining a struct with live instances is asking for trouble; prefer classes for anything long-lived.

## 6. Restarts & the Condition System in SBCL

SBCL fully implements the ANSI **condition system**, which cleanly separates three roles that most languages conflate into "exceptions":

- **Signaling** (`signal`, `warn`, `error`) — announces that something happened, without deciding what to do about it.
- **Restarts** (`restart-case`, `with-simple-restart`) — the *low-level* code declares **named recovery strategies** at the point where recovery is possible.
- **Handlers** (`handler-bind`, `handler-case`) — the *high-level* code decides which restart (if any) to invoke, based on policy.

### 6.1 Why this is special: no unwinding

The critical difference from `try/catch`: when a condition is signaled, **the stack is not unwound**. Handlers run in the dynamic environment of the signaler — with the full stack, local state, and all established restarts still intact. A handler can then `invoke-restart` to resume execution at a chosen restart point. `handler-case` is just a convenience macro that unwinds first; `handler-bind` gives you full non-unwinding control.

```lisp
(defun parse-entry (s)
  (restart-case
      (if (valid-p s)
          (do-parse s)
          (error "Malformed entry: ~A" s))
    (use-value (v) :report "Supply a value to use instead" v)
    (skip-entry () :report "Skip this entry" nil)))

;; High-level policy, decoupled from the low-level recovery options:
(handler-bind ((error (lambda (c)
                        (declare (ignore c))
                        (invoke-restart 'skip-entry))))
  (mapcar #'parse-entry entries))
```

### 6.2 The debugger is the interactive handler

When an unhandled error reaches the top level, SBCL drops you into the **debugger**, which is just an interactive handler presenting all active restarts. In a live server with SLIME/Swank connected:

1. A request thread signals an error → the debugger opens with a **backtrace, inspectable frames, local variables** — the thread is paused, not dead; the rest of the server keeps serving.
2. You **recompile the broken function** in the same image (§3).
3. Invoke the `RETRY`-style restart — execution **resumes from where it failed**, now running the fixed code.

This "fix-and-resume" loop is the core of Lisp's live debugging (famously used to patch NASA's Deep Space 1 from Earth). Standard restarts provided by SBCL include `ABORT` (always present at the REPL), `CONTINUE`, `RETRY`, `USE-VALUE`, `STORE-VALUE` (for unbound variables / slot errors), `MUFFLE-WARNING`, etc. `compute-restarts` lists what's currently available programmatically, enabling fully **automated recovery policies** (e.g. a supervisor that always invokes `skip-entry` on parse errors, logs, and moves on).

### 6.3 Practical patterns

- Establish restarts at low levels (`with-open-file` wrappers, parsers, DB calls), choose them at high levels (request handlers, supervisors).
- Define custom conditions with `define-condition` carrying context in slots, so handlers/restarts can make informed decisions.
- Libraries like **dissect** (backtraces/restarts across threads) and **trivial-backtrace** help in production logging.

## 7. State management

A running SBCL image is a **single persistent heap of live objects**; "state management" is about controlling that heap across reloads, restarts, and image saves.

### 7.1 Global state semantics

- `defvar` — special variable, **only initialized if currently unbound**; re-evaluating the form does *not* clobber an existing value. Good for state you want to preserve across reloads (e.g. `*server*`, `*db-connection*`).
- `defparameter` — special variable, **always re-assigned** on re-evaluation. Good for configuration that should refresh on reload.
- `defconstant` — redefining it is **undefined behavior** (the compiler may have inlined the value); SBCL will often warn/error on redefinition. Use `defparameter` or `sb-ext:defglobal` instead for anything that might change.
- Special variables are **dynamically scoped**, so per-request state is idiomatically done with `let` re-binding (thread-locally), not globals.

### 7.2 State across hot reloads

- Redefining functions/classes does not touch variable values — state survives code reloads by default. This is the whole point of the live image: **code changes, state persists**.
- For class redefinitions, instance state migrates via `update-instance-for-redefined-class` (§3.4); you write methods to map old slots to new.
- Common pattern: a `start`/`stop` protocol (à la **mount**/**Component**-style libraries) that re-initializes only the resources that need it (DB pools, sockets) while leaving cached data alone.
- Delayed initialization with `(defvar *conn* nil)` + `(unless *conn* (setf *conn* (connect)))` makes reload-after-restart behave sanely when old resources (sockets, FDs) are dead.

### 7.3 Image save / restore: `save-lisp-and-die`

`(sb-ext:save-lisp-and-die "app.core")` serializes the **entire current heap** — code, data, and state — to a core image; with `:executable t` you get a standalone binary combining core + runtime.

- `:toplevel #'main` — function to run when the image restarts.
- **`:save-runtime-options t`** — bake runtime options in, so the binary doesn't parse SBCL flags.
- On restore, the process gets a **new PID, new threads, new file descriptors, new OS handles** — anything tied to the OS is stale. SBCL's own save machinery clobbers a curated set of globals (`sb-kernel::+save-lisp-clobbered-globals+`: thread locks, allocator mutexes, TLS maps, exit locks) so the saved image can restart cleanly; your code must do the same for its own OS-level state:
  - Re-open sockets, DB connections, files in the toplevel function.
  - Restart threads in the toplevel (threads do **not** survive saving).
  - Don't capture ephemeral things (streams, foreign pointers) in globals without a re-init hook.
- Foreign libraries loaded via CFFI must be re-loadable on the target machine; `cffi:*foreign-library-directories*` and reloading in toplevel handle this.

### 7.4 Deployment state patterns

- **Dev**: long-lived image, hot-patch via Swank, state naturally accumulates; periodically restart from a clean build to verify reproducibility.
- **Prod**: build binary via `save-lisp-and-die` in CI (clean state), start it fresh; optionally start a Swank server (over SSH tunnel) for live inspection/patching, but treat the binary as the source of truth — image-based state is not versioned code.
- Persistent data belongs in real stores (DB/files); the image heap is a cache/workspace, not a database.

## 8. Sources

- SBCL official site & manual: https://www.sbcl.org/ , https://sbcl.org/manual/
- SBCL internals overview: https://www.xach.com/sbcl/doc/implementation.html
- Quicklisp: https://www.quicklisp.org/beta/ , https://quicklisp.org/beta/faq.html
- Common Lisp Libraries docs (Quicklisp chapter): https://cl-library-docs.github.io/common-lisp-libraries/quicklisp/
- CLHS §4.3.6 Redefining Classes: http://clhs.lisp.se/Body/04_cf.htm
- `update-instance-for-redefined-class`, `change-class` reference: https://lisp-docs.github.io/cl-language-reference/
- SBCL wrapper-cache source (instance update machinery): https://github.com/sbcl/sbcl/blob/master/src/pcl/wrapper.lisp
- Common Lisp Cookbook, CLOS chapter: https://lispcookbook.github.io/cl-cookbook/clos.html
- SO: "How to replace a running function in Common Lisp?" — https://stackoverflow.com/questions/8874615
- SO: "Changing a program while it is running" — https://stackoverflow.com/questions/20259845
- HN: "How does Common Lisp implement hot-reloading?" — https://news.ycombinator.com/item?id=18269770
- Live-reload web example: https://github.com/vindarel/lisp-web-live-reload-example
- Condition system concepts (CLHS ch. 9): https://lisp-docs.github.io/cl-language-reference/chap-9/j-b-condition-system-concepts
- `handler-bind` reference: https://lisp-docs.github.io/cl-language-reference/chap-9/j-c-dictionary/handler-bind_macro
- Tutorial on conditions & restarts: https://lisper.in/restarts
- Common Lisp Docs condition tutorial: https://lisp-docs.github.io/docs/tutorial/conditions
- Cookbook: error handling: https://lispcookbook.github.io/cl-cookbook/error_handling.html
- Practical Common Lisp, ch. 19 ("Beyond Exception Handling: Conditions and Restarts")
- SBCL manual — "Saving a Core Image" / executable delivery: https://sbcl.org/manual/ (§3.2.3)
- SBCL save machinery source: https://github.com/sbcl/sbcl/blob/master/src/code/save.lisp
