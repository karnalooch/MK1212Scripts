// MK1212 static research leads (not executable hooks or multiplayer proof).
// @category MK1212
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.util.DefinedDataIterator;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.Map;
import java.util.TreeMap;
import java.util.regex.Pattern;

public class Mk1212Leads extends GhidraScript {
    private static final int MAX_FINDINGS = 300;
    private static final int MAX_FUNCTIONS = 250000;
    private static final int MAX_STRINGS = 250000;
    private static final int MAX_REFS_PER_STRING = 5;
    private static final Pattern TERMS = Pattern.compile(
        "diplom|treaty|pay(?:ment)?|treasur|negotiat|proposal|offer|multiplayer|" +
        "net.?work|net.?packet|command.?queue|dispatch|serializ|dilemma|incident|turn.?start",
        Pattern.CASE_INSENSITIVE);

    private final TreeMap<String, String> findings = new TreeMap<String, String>();
    private boolean truncated = false;

    private static String json(String s) {
        if (s == null) { return "null"; }
        StringBuilder out = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\') { out.append("\\\\"); }
            else if (c == '"') { out.append("\\\""); }
            else if (c == '\n') { out.append("\\n"); }
            else if (c == '\r') { out.append("\\r"); }
            else if (c == '\t') { out.append("\\t"); }
            else if (c < 0x20) { out.append(' '); }
            else { out.append(c); }
        }
        return out.append('"').toString();
    }

    private static String clipped(String text) {
        if (text == null) { return ""; }
        String clean = text.replace('\r', ' ').replace('\n', ' ').replace('\t', ' ');
        return clean.length() <= 160 ? clean : clean.substring(0, 160);
    }

    private void add(String kind, Address location, Address from, String function, String excerpt) {
        if (findings.size() >= MAX_FINDINGS) {
            truncated = true;
            return;
        }
        String addr = location == null ? "" : location.toString();
        String ref = from == null ? "" : from.toString();
        String key = kind + "|" + addr + "|" + ref + "|" + function;
        if (findings.containsKey(key)) { return; }
        String value = "{" +
            "\"kind\":" + json(kind) + "," +
            "\"address\":" + json(addr) + "," +
            "\"reference\":" + json(ref) + "," +
            "\"function\":" + json(clipped(function)) + "," +
            "\"excerpt\":" + json(clipped(excerpt)) +
            "}";
        findings.put(key, value);
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 2 || !args[1].matches("(?i)[0-9a-f]{64}")) {
            throw new IllegalArgumentException("Usage: Mk1212Leads.java <output-json> <original-pe-sha256>");
        }
        File output = new File(args[0]).getCanonicalFile();
        if (!output.getParentFile().isDirectory() || output.exists()) {
            throw new IllegalStateException("Output directory must exist and output must be new.");
        }
        int functionScanned = 0;
        FunctionIterator funcs = currentProgram.getFunctionManager().getFunctions(true);
        while (funcs.hasNext()) {
            if (monitor.isCancelled()) { throw new InterruptedException("Cancelled function pass."); }
            if (++functionScanned > MAX_FUNCTIONS) { truncated = true; break; }
            Function fn = funcs.next();
            if (TERMS.matcher(fn.getName()).find()) {
                add("named_function", fn.getEntryPoint(), null, fn.getName(), "");
            }
        }

        int stringsScanned = 0;
        DefinedDataIterator data = DefinedDataIterator.definedStrings(currentProgram);
        while (data.hasNext()) {
            if (monitor.isCancelled()) { throw new InterruptedException("Cancelled string pass."); }
            if (++stringsScanned > MAX_STRINGS) { truncated = true; break; }
            Data item = data.next();
            StringDataInstance sdi = StringDataInstance.getStringDataInstance(item);
            String value = sdi == null ? null : sdi.getStringValue();
            if (value == null || !TERMS.matcher(value).find()) { continue; }

            Address stringAddr = item.getAddress();
            add("matched_string", stringAddr, null, "", value);
            ReferenceIterator refs = currentProgram.getReferenceManager().getReferencesTo(stringAddr);
            int refCount = 0;
            while (refs.hasNext() && refCount < MAX_REFS_PER_STRING) {
                Reference r = refs.next();
                Function owner = currentProgram.getFunctionManager().getFunctionContaining(r.getFromAddress());
                add("string_xref", stringAddr, r.getFromAddress(),
                    owner == null ? "" : owner.getName(), value);
                refCount++;
            }
            if (refs.hasNext()) { truncated = true; }
        }

        StringBuilder body = new StringBuilder(64000);
        body.append("{\n")
            .append("\"schema_version\":1,\n")
            .append("\"tool\":\"ghidra\",\n")
            .append("\"binary_sha256\":").append(json(args[1].toLowerCase())).append(",\n")
            .append("\"program\":").append(json(currentProgram.getName())).append(",\n")
            .append("\"status\":\"STATIC_CANDIDATE_ONLY\",\n")
            .append("\"truncated\":").append(truncated).append(",\n")
            .append("\"scanned_functions\":").append(functionScanned).append(",\n")
            .append("\"scanned_strings\":").append(stringsScanned).append(",\n")
            .append("\"findings\":[\n");
        boolean first = true;
        for (Map.Entry<String, String> item : findings.entrySet()) {
            if (!first) { body.append(",\n"); }
            body.append(item.getValue());
            first = false;
        }
        body.append("\n]}\n");
        if (body.length() > 1048576) { throw new IllegalStateException("Bounded output unexpectedly exceeded 1 MiB."); }
        File partial = new File(output.getPath() + ".pending");
        if (partial.exists()) { throw new IllegalStateException("Stale output staging file."); }
        Files.write(partial.toPath(), body.toString().getBytes(StandardCharsets.UTF_8));
        Files.move(partial.toPath(), output.toPath(), StandardCopyOption.ATOMIC_MOVE);
        println("MK1212 RE: " + findings.size() + " static candidates, truncated=" + truncated);
        println("No hook/call address has been verified against live Attila MP.");
    }
}
