import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	access,
	cp,
	lstat,
	mkdir,
	readFile,
	readdir,
	rm,
	writeFile,
} from "node:fs/promises";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_NAME = "tools/build-studio-package.mjs";
const FORMAT_VERSION = 1;
const PACKAGE_NAME = "ReactiveState";
const CLI_TYPE_REQUIRE = 'return require("./src/Types")';
const STUDIO_TYPE_REQUIRE = "return require(script.Types)";

const scriptPath = fileURLToPath(import.meta.url);
const projectRoot = resolve(dirname(scriptPath), "..");
const sourceRoot = join(projectRoot, "src");
const distRoot = join(projectRoot, "dist");
const packageRoot = join(distRoot, PACKAGE_NAME);
const manifestPath = join(distRoot, `${PACKAGE_NAME}.manifest.json`);
const markerPath = join(distRoot, ".reactive-state-package.json");

const expectedSourceFiles = [
	"AttributePreset/init.luau",
	"BehaviorTree/init.luau",
	"Bridge/init.luau",
	"Core/Clock.luau",
	"Core/Codec.luau",
	"Core/FRP.luau",
	"Core/Hash.luau",
	"Core/Immutable.luau",
	"Core/Runtime.luau",
	"Debug/init.luau",
	"Network/init.luau",
	"Network/EventProtocol.luau",
	"Overdare/init.luau",
	"Types.luau",
	"init.luau",
].sort();

const marker = {
	formatVersion: FORMAT_VERSION,
	managedBy: SCRIPT_NAME,
};

function toPortablePath(value) {
	return value.split(sep).join("/");
}

function sha256(value) {
	return createHash("sha256").update(value).digest("hex");
}

function invariant(condition, message) {
	if (!condition) {
		throw new Error(message);
	}
}

function studioSource(file, source) {
	if (file !== "init.luau") {
		return source;
	}
	const parts = source.split(CLI_TYPE_REQUIRE);
	invariant(
		parts.length === 2,
		"Root type-require transform must match exactly once"
	);
	return parts.join(STUDIO_TYPE_REQUIRE);
}

function parseInteger(source, pattern, label) {
	const match = source.match(pattern);
	invariant(match !== null, `Could not read ${label}`);
	return Number(match[1]);
}

function parseString(source, pattern, label) {
	const match = source.match(pattern);
	invariant(match !== null, `Could not read ${label}`);
	return match[1];
}

async function readMetadata() {
	const [rootSource, hashSource, networkSource, eventProtocolSource] = await Promise.all([
		readFile(join(sourceRoot, "init.luau"), "utf8"),
		readFile(join(sourceRoot, "Core", "Hash.luau"), "utf8"),
		readFile(join(sourceRoot, "Network", "init.luau"), "utf8"),
		readFile(join(sourceRoot, "Network", "EventProtocol.luau"), "utf8"),
	]);

	const studioRequireContracts = [
		[rootSource, "dynamicRequire(script.Core.FRP)", "root -> Core.FRP"],
		[rootSource, "dynamicRequire(script.Core.Runtime)", "root -> Core.Runtime"],
		[rootSource, "dynamicRequire(script.Core.Clock)", "root -> Core.Clock"],
		[rootSource, "dynamicRequire(script.Core.Codec)", "root -> Core.Codec"],
		[rootSource, "dynamicRequire(script.Core.Hash)", "root -> Core.Hash"],
		[rootSource, "dynamicRequire(script.Core.Immutable)", "root -> Core.Immutable"],
		[networkSource, "require(script.Parent.Core.Codec)", "Network -> Core.Codec"],
		[networkSource, "require(script.Parent.Core.Hash)", "Network -> Core.Hash"],
		[networkSource, "require(script.EventProtocol)", "Network -> Network.EventProtocol"],
		[eventProtocolSource, "require(script.Parent.Parent.Core.Codec)", "Network.EventProtocol -> Core.Codec"],
	];
	for (const [source, reference, label] of studioRequireContracts) {
		invariant(source.includes(reference), `Studio require contract is missing or stale: ${label}`);
	}

	return {
		stateVersion: parseString(rootSource, /\bVERSION\s*=\s*"([^"]+)"/, "State.VERSION"),
		apiVersion: parseInteger(rootSource, /\bAPI_VERSION\s*=\s*(\d+)/, "State.API_VERSION"),
		canonicalVersion: parseInteger(
			hashSource,
			/\bCANONICAL_VERSION\s*=\s*(\d+)/,
			"Hash.CANONICAL_VERSION"
		),
		networkProtocolVersion: parseInteger(
			networkSource,
			/\bPROTOCOL_VERSION\s*=\s*(\d+)/,
			"Network.PROTOCOL_VERSION"
		),
		eventProtocolVersion: parseInteger(
			eventProtocolSource,
			/\bEVENT_PROTOCOL_VERSION\s*=\s*(\d+)/,
			"Network.EVENT_PROTOCOL_VERSION"
		),
	};
}

async function walkFiles(root) {
	const files = [];

	async function visit(directory) {
		const entries = await readdir(directory, { withFileTypes: true });
		entries.sort((left, right) => left.name.localeCompare(right.name));

		for (const entry of entries) {
			const absolutePath = join(directory, entry.name);
			if (entry.isDirectory()) {
				await visit(absolutePath);
			} else if (entry.isFile()) {
				files.push(toPortablePath(relative(root, absolutePath)));
			} else {
				throw new Error(`Package source may not contain links or special files: ${absolutePath}`);
			}
		}
	}

	await visit(root);
	return files.sort();
}

function arraysEqual(left, right) {
	return left.length === right.length && left.every((value, index) => value === right[index]);
}

async function assertSourceLayout() {
	const files = await walkFiles(sourceRoot);
	invariant(
		arraysEqual(files, expectedSourceFiles),
		[
			"The public source layout changed. Update expectedSourceFiles and review the Studio object mapping.",
			`Expected: ${expectedSourceFiles.join(", ")}`,
			`Actual:   ${files.join(", ")}`,
		].join("\n")
	);
	for (const file of files) {
		invariant(file.endsWith(".luau"), `Unexpected non-Luau package file: ${file}`);
	}
	return files;
}

function buildStudioObjects(files) {
	const directories = new Set([""]);
	for (const file of files) {
		let directory = dirname(file);
		while (directory !== "." && directory !== "") {
			directories.add(toPortablePath(directory));
			directory = dirname(directory);
		}
	}

	const moduleDirectories = new Set(
		files
			.filter((file) => basename(file) === "init.luau")
			.map((file) => {
				const directory = toPortablePath(dirname(file));
				return directory === "." ? "" : directory;
			})
	);

	const objects = [
		{
			studioPath: PACKAGE_NAME,
			className: "ModuleScript",
			sourcePath: "init.luau",
		},
	];

	const nestedDirectories = [...directories]
		.filter((directory) => directory !== "")
		.sort((left, right) => {
			const depthDifference = left.split("/").length - right.split("/").length;
			return depthDifference !== 0 ? depthDifference : left.localeCompare(right);
		});

	for (const directory of nestedDirectories) {
		const isModule = moduleDirectories.has(directory);
		objects.push({
			studioPath: `${PACKAGE_NAME}/${directory}`,
			className: isModule ? "ModuleScript" : "Folder",
			...(isModule ? { sourcePath: `${directory}/init.luau` } : {}),
		});
	}

	for (const file of files) {
		if (basename(file) === "init.luau") {
			continue;
		}
		objects.push({
			studioPath: `${PACKAGE_NAME}/${file.slice(0, -".luau".length)}`,
			className: "ModuleScript",
			sourcePath: file,
		});
	}

	return objects.sort((left, right) => {
		const depthDifference = left.studioPath.split("/").length - right.studioPath.split("/").length;
		return depthDifference !== 0 ? depthDifference : left.studioPath.localeCompare(right.studioPath);
	});
}

async function makeFileRecords(root, files) {
	const records = [];
	for (const file of files) {
		const contents = await readFile(join(root, file));
		records.push({
			path: file,
			size: contents.byteLength,
			sha256: sha256(contents),
		});
	}
	return records;
}

function packageHash(fileRecords) {
	const hash = createHash("sha256");
	for (const file of fileRecords) {
		hash.update(file.path);
		hash.update("\0");
		hash.update(file.sha256);
		hash.update("\n");
	}
	return hash.digest("hex");
}

function gitInfo() {
	const commitResult = spawnSync("git", ["rev-parse", "--verify", "HEAD"], {
		cwd: projectRoot,
		encoding: "utf8",
	});
	const statusResult = spawnSync("git", ["status", "--porcelain"], {
		cwd: projectRoot,
		encoding: "utf8",
	});

	return {
		sourceCommit: commitResult.status === 0 ? commitResult.stdout.trim() : null,
		workingTreeDirty: statusResult.status === 0 ? statusResult.stdout.trim().length > 0 : null,
	};
}

function longBracket(value) {
	for (let equalsCount = 0; equalsCount <= 32; equalsCount += 1) {
		const equals = "=".repeat(equalsCount);
		const closing = `]${equals}]`;
		if (!value.includes(closing)) {
			return `[${equals}[${value}]${equals}]`;
		}
	}
	throw new Error("Could not encode a Luau long-bracket string");
}

async function buildInstaller(objects, metadata, digest) {
	const sourceByPath = new Map();
	for (const object of objects) {
		if (object.sourcePath !== undefined) {
			sourceByPath.set(object.sourcePath, await readFile(join(packageRoot, object.sourcePath), "utf8"));
		}
	}

	const lines = [
		"-- Generated by tools/build-studio-package.mjs. Do not edit this artifact.",
		`-- ReactiveState ${metadata.stateVersion}; package SHA-256 ${digest}`,
		"-- Run only in OVERDARE Studio's trusted edit-time command environment.",
		"",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		`if ReplicatedStorage:FindFirstChild(${JSON.stringify(PACKAGE_NAME)}) ~= nil then`,
		`\terror(${JSON.stringify(`${PACKAGE_NAME} already exists in ReplicatedStorage; refusing to overwrite it`)}, 0)`,
		"end",
		"",
		"local createdRoot = nil",
		"local ok, installError = pcall(function()",
		"\tlocal nodes = {}",
	];

	for (const [index, object] of objects.entries()) {
		const variable = `node${index + 1}`;
		const pathParts = object.studioPath.split("/");
		const objectName = pathParts[pathParts.length - 1];
		const parentPath = pathParts.slice(0, -1).join("/");
		lines.push(`\tlocal ${variable} = Instance.new(${JSON.stringify(object.className)})`);
		lines.push(`\t${variable}.Name = ${JSON.stringify(objectName)}`);
		if (object.sourcePath !== undefined) {
			lines.push(`\t${variable}.Source = ${longBracket(sourceByPath.get(object.sourcePath))}`);
		}
		if (index === 0) {
			lines.push(`\tcreatedRoot = ${variable}`);
			lines.push(`\tnodes[${JSON.stringify(object.studioPath)}] = ${variable}`);
		} else {
			lines.push(`\t${variable}.Parent = nodes[${JSON.stringify(parentPath)}]`);
			lines.push(`\tnodes[${JSON.stringify(object.studioPath)}] = ${variable}`);
		}
		lines.push("");
	}

	lines.push(
		`\tcreatedRoot:SetAttribute("ReactiveStateVersion", ${JSON.stringify(metadata.stateVersion)})`,
		`\tcreatedRoot:SetAttribute("ReactiveStateApiVersion", ${metadata.apiVersion})`,
		`\tcreatedRoot:SetAttribute("ReactiveStateCanonicalVersion", ${metadata.canonicalVersion})`,
		`\tcreatedRoot:SetAttribute("ReactiveStateNetworkProtocolVersion", ${metadata.networkProtocolVersion})`,
		`\tcreatedRoot:SetAttribute("ReactiveStateEventProtocolVersion", ${metadata.eventProtocolVersion})`,
		`\tcreatedRoot:SetAttribute("ReactiveStatePackageSha256", ${JSON.stringify(digest)})`,
		"\tcreatedRoot.Parent = ReplicatedStorage",
		"end)",
		"",
		"if not ok then",
		"\tif createdRoot ~= nil then",
		"\t\tcreatedRoot:Destroy()",
		"\tend",
		'\terror("ReactiveState installation failed: " .. tostring(installError), 0)',
		"end",
		"",
		`print(${JSON.stringify(`Installed ${PACKAGE_NAME} ${metadata.stateVersion} at ReplicatedStorage/${PACKAGE_NAME}`)})`,
		""
	);

	return lines.join("\n");
}

async function pathExists(path) {
	try {
		await access(path);
		return true;
	} catch {
		return false;
	}
}

async function prepareDist() {
	invariant(resolve(distRoot) === join(projectRoot, "dist"), "Refusing to manage an unexpected output path");
	if (await pathExists(distRoot)) {
		invariant((await lstat(distRoot)).isDirectory(), "dist exists but is not a directory");
		invariant(await pathExists(markerPath), "Refusing to replace an unmanaged dist directory");
		const existingMarker = JSON.parse(await readFile(markerPath, "utf8"));
		invariant(
			existingMarker.managedBy === marker.managedBy && existingMarker.formatVersion === marker.formatVersion,
			"Refusing to replace dist because its package marker is not recognized"
		);
		await rm(distRoot, { recursive: true, force: true });
	}
	await mkdir(distRoot, { recursive: true });
	await writeFile(markerPath, `${JSON.stringify(marker, null, 2)}\n`);
}

async function artifactRecord(path) {
	const contents = await readFile(join(distRoot, path));
	return {
		path,
		size: contents.byteLength,
		sha256: sha256(contents),
	};
}

async function build() {
	const files = await assertSourceLayout();
	const metadata = await readMetadata();
	const studioObjects = buildStudioObjects(files);
	await prepareDist();
	await cp(sourceRoot, packageRoot, { recursive: true, force: false, errorOnExist: true });
	const packageRootPath = join(packageRoot, "init.luau");
	const rootSource = await readFile(packageRootPath, "utf8");
	await writeFile(packageRootPath, studioSource("init.luau", rootSource));

	const fileRecords = await makeFileRecords(packageRoot, files);
	const digest = packageHash(fileRecords);
	const installer = await buildInstaller(studioObjects, metadata, digest);

	await Promise.all([
		cp(join(projectRoot, "docs", "studio-install.md"), join(distRoot, "INSTALL.md")),
		cp(join(projectRoot, "LICENSE"), join(distRoot, "LICENSE")),
		cp(join(projectRoot, "NOTICE.md"), join(distRoot, "NOTICE.md")),
		writeFile(join(distRoot, "StudioInstaller.luau"), installer),
		writeFile(
			join(distRoot, `${PACKAGE_NAME}.project.json`),
			`${JSON.stringify({ name: PACKAGE_NAME, tree: { $path: PACKAGE_NAME } }, null, 2)}\n`
		),
	]);

	const artifactPaths = [
		".reactive-state-package.json",
		"INSTALL.md",
		"LICENSE",
		"NOTICE.md",
		`${PACKAGE_NAME}.project.json`,
		"StudioInstaller.luau",
	];
	const artifacts = [];
	for (const artifactPath of artifactPaths) {
		artifacts.push(await artifactRecord(artifactPath));
	}

	const manifest = {
		formatVersion: FORMAT_VERSION,
		generatedBy: SCRIPT_NAME,
		package: {
			name: PACKAGE_NAME,
			stateVersion: metadata.stateVersion,
			apiVersion: metadata.apiVersion,
			canonicalVersion: metadata.canonicalVersion,
			networkProtocolVersion: metadata.networkProtocolVersion,
			eventProtocolVersion: metadata.eventProtocolVersion,
			artifactType: "multi-module-source-tree",
			installRoot: `ReplicatedStorage/${PACKAGE_NAME}`,
		},
		build: {
			sourceRoot: "src",
			...gitInfo(),
			packageHashAlgorithm: "sha256(path + NUL + fileSha256 + LF, sorted by path)",
			packageSha256: digest,
		},
		files: fileRecords,
		studioObjects,
		artifacts,
		excludedFromRuntimePackage: ["benchmarks", "docs", "examples", "tests", "tools"],
	};

	await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
	console.log(`Built ${PACKAGE_NAME} ${metadata.stateVersion}`);
	console.log(`  package:  ${toPortablePath(relative(projectRoot, packageRoot))}`);
	console.log(`  installer:${toPortablePath(relative(projectRoot, join(distRoot, "StudioInstaller.luau")))}`);
	console.log(`  manifest: ${toPortablePath(relative(projectRoot, manifestPath))}`);
	console.log(`  sha256:   ${digest}`);
}

async function verify() {
	const files = await assertSourceLayout();
	const metadata = await readMetadata();
	invariant(await pathExists(manifestPath), "Package manifest is missing; run the builder first");
	const manifest = JSON.parse(await readFile(manifestPath, "utf8"));

	invariant(manifest.formatVersion === FORMAT_VERSION, "Manifest format version mismatch");
	invariant(manifest.generatedBy === SCRIPT_NAME, "Manifest generator mismatch");
	invariant(manifest.package.name === PACKAGE_NAME, "Manifest package name mismatch");
	invariant(manifest.package.stateVersion === metadata.stateVersion, "Package state version is stale");
	invariant(manifest.package.apiVersion === metadata.apiVersion, "Package API version is stale");
	invariant(manifest.package.canonicalVersion === metadata.canonicalVersion, "Canonical version is stale");
	invariant(
		manifest.package.networkProtocolVersion === metadata.networkProtocolVersion,
		"Network protocol version is stale"
	);
	invariant(
		manifest.package.eventProtocolVersion === metadata.eventProtocolVersion,
		"Event protocol version is stale"
	);

	const actualPackageFiles = await walkFiles(packageRoot);
	invariant(arraysEqual(actualPackageFiles, files), "Packaged source file list does not match src");
	const actualRecords = await makeFileRecords(packageRoot, files);
	invariant(JSON.stringify(actualRecords) === JSON.stringify(manifest.files), "Packaged source hashes do not match manifest");
	invariant(packageHash(actualRecords) === manifest.build.packageSha256, "Package SHA-256 mismatch");
	invariant(
		JSON.stringify(buildStudioObjects(files)) === JSON.stringify(manifest.studioObjects),
		"Studio object mapping mismatch"
	);

	for (const file of files) {
		const [sourceContents, packageContents] = await Promise.all([
			readFile(join(sourceRoot, file), "utf8"),
			readFile(join(packageRoot, file), "utf8"),
		]);
		invariant(studioSource(file, sourceContents) === packageContents, `Packaged file is stale: ${file}`);
	}

	for (const artifact of manifest.artifacts) {
		const actual = await artifactRecord(artifact.path);
		invariant(JSON.stringify(actual) === JSON.stringify(artifact), `Artifact hash mismatch: ${artifact.path}`);
	}

	const allowedDistFiles = new Set([...manifest.artifacts.map((artifact) => artifact.path), basename(manifestPath)]);
	const distFiles = await walkFiles(distRoot);
	const packagePrefix = `${PACKAGE_NAME}/`;
	const extraFiles = distFiles.filter((file) => !file.startsWith(packagePrefix) && !allowedDistFiles.has(file));
	invariant(extraFiles.length === 0, `Unexpected files in dist: ${extraFiles.join(", ")}`);

	console.log(`Verified ${PACKAGE_NAME} ${metadata.stateVersion}`);
	console.log(`  files:  ${files.length}`);
	console.log(`  objects:${manifest.studioObjects.length}`);
	console.log(`  sha256: ${manifest.build.packageSha256}`);
}

function printHelp() {
	console.log("Usage: node tools/build-studio-package.mjs [--verify]");
}

try {
	if (process.argv.length === 2) {
		await build();
	} else if (process.argv.length === 3 && process.argv[2] === "--verify") {
		await verify();
	} else if (process.argv.length === 3 && ["--help", "-h"].includes(process.argv[2])) {
		printHelp();
	} else {
		printHelp();
		process.exitCode = 2;
	}
} catch (error) {
	console.error(`Studio package error: ${error instanceof Error ? error.message : String(error)}`);
	process.exitCode = 1;
}
