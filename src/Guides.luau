--!strict

-- START HERE when this package is the only artifact available in Studio.
-- This module is descriptive and side-effect free: requiring it never creates
-- an Instance, connects an engine signal, or starts a network channel.

export type Route = {
	read useWhen: string,
	read entryPoint: string,
	read readNext: string,
}

export type ReadonlyStringList = { read [number]: string }

export type ServerAuthoritativeMultiplayerGuide = {
	read id: string,
	read useWhen: string,
	read state: string,
	read protocol: string,
	read serverTransport: string,
	read clientTransport: string,
	read serverInput: string,
	read clientInput: string,
	read initialSync: string,
	read steps: ReadonlyStringList,
	read invariants: ReadonlyStringList,
	read avoid: ReadonlyStringList,
	read verification: ReadonlyStringList,
}

export type Guides = {
	read GUIDE_VERSION: number,
	read START_HERE: string,
	read routes: {
		read pushPullFRP: Route,
		read localGameState: Route,
		read serverAuthoritativeMultiplayer: Route,
	},
	read serverAuthoritativeMultiplayer: ServerAuthoritativeMultiplayerGuide,
}

local routes = table.freeze({
	pushPullFRP = table.freeze({
		useWhen = "Time, occurrence ordering, or an Event/Reactive graph is part of the domain.",
		entryPoint = "ReactiveState.newHost",
		readNext = "ReactiveState.Guides.serverAuthoritativeMultiplayer when a RemoteEvent crosses the boundary.",
	}),
	localGameState = table.freeze({
		useWhen = "Score, round, HUD, or other synchronous Atom/Computed game state stays in one process.",
		entryPoint = "ReactiveState.createCapital (or createStateRuntime for lowercase APIs)",
		readNext = "Capital is local state, not a server/client transport.",
	}),
	serverAuthoritativeMultiplayer = table.freeze({
		useWhen = "Clients send intent and only the server may publish authoritative state.",
		entryPoint = "require(packageRoot.Network).defineFRPProtocol + require(packageRoot.Overdare).attachFRP*Remote",
		readNext = "ReactiveState.Guides.serverAuthoritativeMultiplayer",
	}),
})

local serverAuthoritativeMultiplayer = table.freeze({
	id = "server-authoritative-multiplayer-v1",
	useWhen = "A multiplayer game has authoritative score, inventory, round, combat, or world state.",
	state = "Use ReactiveState.createCapital for synchronous score/round state, or ReactiveState.newHost for an FRP Event graph.",
	protocol = "require(packageRoot.Network).defineFRPProtocol(messages, options)",
	serverTransport = "require(packageRoot.Overdare).attachFRPServerRemote(driver, remoteEvent, { protocol, authorize, buildSnapshot })",
	clientTransport = "require(packageRoot.Overdare).attachFRPClientRemote(driver, remoteEvent, { protocol, initialResync = true })",
	serverInput = "channel:intents():subscribe(function(intent) ... end)",
	clientInput = "channel:authority():subscribe(function(message) ... end)",
	initialSync = "Provide buildSnapshot on the server and keep initialResync enabled on the client.",
	steps = table.freeze({
		"Define one shared protocol with CLIENT_INTENT and SERVER_TO_CLIENT message directions.",
		"Create one Host and one Overdare Heartbeat driver in each server/client process.",
		"Attach the server/client RemoteEvent channels with the same protocol.",
		"Validate and authorize intent on the server before changing game state.",
		"Publish only server-created events or snapshots to clients.",
		"Dispose channel, driver, Host, and state facade when the match/session ends.",
	}),
	invariants = table.freeze({
		"A client payload never contains an authoritative score or replacement snapshot.",
		"Player identity comes from the RemoteEvent sender supplied by the server transport.",
		"Rate, payload, sequence, replay, and resync policy belong to Network, not ad-hoc RemoteEvent handlers.",
		"Commit reactive state before changing Instance properties or sending external effects.",
		"Keep a stable match roster and derive collection counts from the authoritative collection.",
	}),
	avoid = table.freeze({
		"Do not create a project-local ReactiveState shim.",
		"Do not use Capital.Bus or Capital.Event as a server/client transport.",
		"Do not rebuild protocol sequencing, rate limiting, retry, or resync with raw RemoteEvent callbacks.",
		"Do not treat a syntax-only or one-client run as multiplayer verification.",
	}),
	verification = table.freeze({
		"Run one-client initial snapshot and reconnect tests.",
		"Run two-client authority, isolation, duplicate, and round-completion tests.",
		"Run a third-client join and active-player disconnect test.",
		"Verify rate limits, malformed payload rejection, cleanup, and a fresh non-stale output log.",
	}),
})

local Guides: Guides = table.freeze({
	GUIDE_VERSION = 1,
	START_HERE = "Bind packageRoot to ReplicatedStorage:WaitForChild(\"ReactiveState\"), require it, then choose a route in ReactiveState.Guides.routes. For server-authoritative multiplayer, read ReactiveState.Guides.serverAuthoritativeMultiplayer before creating RemoteEvents.",
	routes = routes,
	serverAuthoritativeMultiplayer = serverAuthoritativeMultiplayer,
})

return Guides
