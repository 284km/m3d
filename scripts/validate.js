// A command line around the Khronos glTF validator, which npm ships as a library.
//
// WHY IT IS HERE AT ALL. The other two readers of these files -- this project and
// scripts/gltf_oracle.py -- agree with each other, and both read the same specification
// the same way. Neither can say whether the FILE is legal glTF. That matters in one
// direction especially: the synthetic model in test/data is written by a script in this
// repository, and a differential test over a file we invented proves that two readers
// agree about bytes we chose. The validator is the outside opinion that those bytes are
// a glTF at all.
//
//   node scripts/validate.js <file.gltf|file.glb> ...
//
// Exits non-zero if any file has errors. Warnings are printed and not fatal: the sample
// models carry several (unused texture coordinates and the like) and failing on those
// would be enforcing tidiness rather than legality.
const fs = require('fs');
const path = require('path');
const validator = require('gltf-validator');

async function one(file) {
  const bytes = new Uint8Array(fs.readFileSync(file));
  const dir = path.dirname(file);
  const report = await validator.validateBytes(bytes, {
    uri: file,
    // A .gltf names its buffers and images as separate files; without this the validator
    // reports them as unresolvable and every external-buffer model "fails".
    externalResourceFunction: (uri) =>
      new Promise((resolve, reject) => {
        try { resolve(new Uint8Array(fs.readFileSync(path.join(dir, decodeURIComponent(uri))))); }
        catch (e) { reject(e); }
      }),
  });
  const { numErrors, numWarnings, numInfos } = report.issues;
  const name = path.basename(file);
  if (numErrors > 0) {
    console.log(`  ${name}: ${numErrors} ERROR(S)`);
    for (const m of report.issues.messages.filter(m => m.severity === 0).slice(0, 5)) {
      console.log(`      ${m.code} at ${m.pointer}: ${m.message}`);
    }
    return false;
  }
  console.log(`  ${name}: valid (${numWarnings} warning(s), ${numInfos} info)`);
  return true;
}

(async () => {
  const files = process.argv.slice(2);
  if (files.length === 0) { console.log('validate: no files given, which is not a pass'); process.exit(1); }
  let ok = true;
  for (const f of files) { if (!await one(f)) ok = false; }
  console.log(`validate: ${files.length} file(s) checked`);
  process.exit(ok ? 0 : 1);
})();
