import { spawnSync } from "node:child_process";
import { copyFile, readFile, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const analyzer = process.env.LUAU_ANALYZE || "luau-analyze";
const toolchain = JSON.parse(
	await readFile(resolve(projectRoot, "tools/luau-toolchain.json"), "utf8")
);
const capabilityFile = "tests/typecheck/analyzer_capabilities.luau";
const positiveFiles = [
	"src/Types.luau",
	"src/init.luau",
	"tests/typecheck/frp_public.luau",
	"tests/typecheck/capital_public.luau",
];
const negativeFixtures = [
	{
		name: "frp",
		source: "tests/typecheck/frp_public.negative.luau.disabled",
		check: "tests/typecheck/.frp_public.negative.check.luau",
		expectedErrors: 7,
		requiredText: "is read-only",
	},
	{
		name: "capital",
		source: "tests/typecheck/capital_public.negative.luau.disabled",
		check: "tests/typecheck/.capital_public.negative.check.luau",
		expectedErrors: 5,
	},
];

function run(files) {
	const result = spawnSync(analyzer, files, {
		cwd: projectRoot,
		encoding: "utf8",
	});
	if (result.error) {
		throw new Error(`Could not run ${analyzer}: ${result.error.message}`);
	}
	return {
		status: result.status,
		output: `${result.stdout || ""}${result.stderr || ""}`,
	};
}

const capability = run([capabilityFile]);
if (capability.status !== 0) {
	process.stderr.write(capability.output);
	throw new Error([
		"incompatible Luau analyzer: required read-only property and recursive generic syntax is unavailable",
		`use official luau-analyze from ${toolchain.repository} at commit ${toolchain.commit}`,
		"luau-lsp analyze is an editor frontend and is not a compatible substitute for this gate",
	].join("; "));
}

const positive = run(positiveFiles);
if (positive.status !== 0) {
	process.stderr.write(positive.output);
	throw new Error("strict public FRP positive fixture failed");
}

for (const fixture of negativeFixtures) {
	const source = resolve(projectRoot, fixture.source);
	const check = resolve(projectRoot, fixture.check);
	try {
		await copyFile(source, check);
		const negative = run([fixture.check]);
		const errorCount = (negative.output.match(/TypeError:/g) || []).length;
		if (
			negative.status === 0
			|| errorCount !== fixture.expectedErrors
			|| (fixture.requiredText != null && !negative.output.includes(fixture.requiredText))
			|| negative.output.includes("Unknown require")
		) {
			process.stderr.write(negative.output);
			throw new Error(
				`strict public ${fixture.name} negative fixture expected ${fixture.expectedErrors} contract errors, got ${errorCount}`
			);
		}
	} finally {
		await rm(check, { force: true });
	}
}

console.log(
	`PASS strict public types (positive=0 errors, frp-negative=7, capital-negative=5, baseline=${toolchain.commit.slice(0, 12)})`
);
