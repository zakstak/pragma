// Parse the supported shell boundary once; execution always uses argv.
const path = require("node:path");

function tokenize(script) {
  if (typeof script !== "string" || !script.trim())
    throw new Error("typecheck script must be a nonempty string");
  const commands = [[]];
  let word = "",
    quote = null,
    started = false;
  const finish = () => {
    if (started) commands.at(-1).push(word);
    word = "";
    started = false;
  };
  for (let index = 0; index < script.length; index++) {
    const char = script[index];
    if (char === "\\" && quote !== "'") {
      const next = script[++index];
      if (next === undefined || next === "\n")
        throw new Error("unsupported shell escape");
      if (quote === '"' && !["$", "`", '"', "\\"].includes(next))
        word += `\\${next}`;
      else word += next;
      started = true;
    } else if (quote) {
      if (char === quote) quote = null;
      else {
        if (quote === '"' && (char === "$" || char === "`"))
          throw new Error("shell expansion is unsupported");
        word += char;
      }
    } else if (char === "'" || char === '"') {
      quote = char;
      started = true;
    } else if (char === "\n" || char === "\r")
      throw new Error("multiline shell commands are unsupported");
    else if (/\s/.test(char)) finish();
    else if (char === "&" && script[index + 1] === "&") {
      finish();
      if (!commands.at(-1).length) throw new Error("empty command");
      commands.push([]);
      index++;
    } else {
      if (";&|<>`$(){}*?[]~#".includes(char))
        throw new Error("shell composition or expansion is unsupported");
      word += char;
      started = true;
    }
  }
  if (quote) throw new Error("unclosed shell quote");
  finish();
  if (!commands.at(-1).length) throw new Error("empty command");
  return commands;
}

function compilerArgs(command, compilerName) {
  let args;
  if (
    [
      compilerName,
      `./node_modules/.bin/${compilerName}`,
      `node_modules/.bin/${compilerName}`,
    ].includes(command[0])
  )
    args = command.slice(1);
  else if (
    compilerName === "tsc" &&
    command[0] === "node" &&
    /^(\.\/)?node_modules\/typescript\/bin\/tsc$/.test(command[1] || "")
  )
    args = command.slice(2);
  else if (["npx", "bunx"].includes(command[0])) {
    const offset = command[1] === "--no-install" ? 2 : 1;
    if (command[offset] === compilerName) args = command.slice(offset + 1);
  } else if (
    ["pnpm", "bun"].includes(command[0]) &&
    command[1] === "exec" &&
    command[2] === compilerName
  )
    args = command.slice(3);
  else if (
    command[0] === "npm" &&
    command[1] === "exec" &&
    command[2] === "--" &&
    command[3] === compilerName
  )
    args = command.slice(4);
  if (!args)
    throw new Error(
      "script contains a framework, custom command, or workspace wrapper rather than direct tsc",
    );
  const optionNames = args
    .filter((arg) => arg.startsWith("-"))
    .map((arg) => arg.split("=", 1)[0].replace(/^-+/, "").toLowerCase());
  if (
    optionNames.some((arg) =>
      [
        "watch",
        "w",
        "help",
        "h",
        "version",
        "v",
        "clean",
        "listfilesonly",
        "showconfig",
        "init",
        "generatetrace",
        "generatecpuprofile",
      ].includes(arg),
    )
  )
    throw new Error(
      "watch, maintenance, profiling, or introspection commands are not read-only compiler checks",
    );
  if (optionNames.some((arg) => ["build", "b"].includes(arg)))
    throw new Error(
      "build mode writes referenced-project state; discovered configs are checked separately in TS-only scope",
    );
  return args;
}

function scriptPlan(script, compilerName = "tsc") {
  try {
    return {
      supported: true,
      commands: tokenize(script).map((command) =>
        compilerArgs(command, compilerName),
      ),
      reason: null,
    };
  } catch (error) {
    return { supported: false, commands: [], reason: error.message };
  }
}

function readOnlyArgs(args, outputDirectory, index) {
  // Preserve input flags and project paths. Last options override emit/cache paths.
  return [
    ...args,
    "--noEmit",
    "true",
    "--incremental",
    "true",
    "--tsBuildInfoFile",
    path.join(outputDirectory, `${index}.tsbuildinfo`),
    "--pretty",
    "false",
  ];
}

module.exports = { tokenize, scriptPlan, readOnlyArgs };
