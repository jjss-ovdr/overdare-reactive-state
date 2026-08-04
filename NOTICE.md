# Design references

ReactiveState is an independent implementation. Its reactive graph and public
contracts were informed by these open-source projects and primary sources:

- Conal Elliott, "Push-pull functional reactive programming," Haskell
  Symposium 2009: <http://conal.net/papers/push-pull-frp/>. The `Future`,
  `Event`, `Reactive`, `Fun`, and `Behavior` denotations and their algebraic
  laws are the semantic basis of the 0.2 Core. The strict Luau scheduler and
  OVERDARE adapters are independently implemented; the paper source code is
  not distributed with this package.

- Alien Signals (MIT): <https://github.com/stackblitz/alien-signals>
- Roblox Signals (MIT): <https://github.com/Roblox/signals>
- Fusion (MIT): <https://github.com/dphfox/Fusion>
- Charm (MIT): <https://github.com/littensy/charm>
- Flux (MIT): <https://github.com/kohltastrophe/flux>
- Solid (MIT): <https://github.com/solidjs/solid>
- Vue reactivity (MIT): <https://github.com/vuejs/core>
- MobX (MIT): <https://github.com/mobxjs/mobx>
- Angular Signals (MIT): <https://github.com/angular/angular/tree/main/packages/core/primitives/signals>
- Preact Signals (MIT): <https://github.com/preactjs/signals>
- Vide (MIT): <https://github.com/centau/vide>
- Reflex: <https://github.com/reflex-frp/reflex>
- Sodium FRP: <https://github.com/SodiumFRP/sodium>

OVERDARE engine boundaries and packaging guidance were checked against the
official Creator documentation:

- Luau guide: <https://docs.overdare.com/manual/script-manual/get-started/luau-guide>
- ModuleScript: <https://docs.overdare.com/development/api-reference/classes/modulescript>
- RunService: <https://docs.overdare.com/api-reference/classes/runservice>
- RemoteEvent: <https://docs.overdare.com/development/api-reference/classes/remoteevent>
- Instance: <https://docs.overdare.com/development/api-reference/classes/instance>

No source file from the paper or those projects is copied into this repository. Their
licenses and copyright notices remain with their respective projects.
