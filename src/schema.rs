//! Reusable JSON Schema plans consuming the source scanner's value events.
//!
//! Input is never reparsed. Ordinary property assertions retain failed keys
//! only (so later duplicates can replace them), not all successful members.
//! String bodies are retained only for pattern/format/contentEncoding/equality;
//! enum/const/uniqueItems retain the subvalues required for exact equality.
mod formats;
mod number;
mod parse;
mod stream;
use number::Decimal;
use regress::Regex;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;
pub use stream::Validator;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Canon {
    Null,
    Bool(bool),
    Num(Decimal),
    Str(String),
    Arr(Vec<Canon>),
    Obj(BTreeMap<String, Canon>),
}
impl Canon {
    fn from_json(v: &Value) -> Self {
        match v {
            Value::Null => Self::Null,
            Value::Bool(b) => Self::Bool(*b),
            Value::Number(n) => Self::Num(Decimal::parse(&n.to_string()).expect("JSON number")),
            Value::String(s) => Self::Str(s.clone()),
            Value::Array(v) => Self::Arr(v.iter().map(Self::from_json).collect()),
            Value::Object(v) => Self::Obj(
                v.iter()
                    .map(|(k, v)| (k.clone(), Self::from_json(v)))
                    .collect(),
            ),
        }
    }
    fn retained_bytes(&self) -> usize {
        match self {
            Self::Str(s) => s.capacity(),
            Self::Num(n) => n.retained_bytes(),
            Self::Arr(a) => {
                a.iter().map(Self::retained_bytes).sum::<usize>()
                    + a.capacity() * std::mem::size_of::<Self>()
            }
            Self::Obj(o) => o
                .iter()
                .map(|(k, v)| k.capacity() + v.retained_bytes() + std::mem::size_of::<Self>())
                .sum(),
            _ => 0,
        }
    }
}
#[derive(Default)]
struct Node {
    spec: Value,
    edges: HashMap<String, usize>,
    lists: HashMap<String, Vec<usize>>,
    properties: HashMap<String, usize>,
    patterns: Vec<(Regex, usize)>,
    dependencies: HashMap<String, Dependency>,
    pattern: Option<Regex>,
    numbers: HashMap<String, Decimal>,
    counts: HashMap<String, u64>,
    choices: Option<Vec<Canon>>,
    constant: Option<Canon>,
    watch: HashSet<String>,
}
enum Dependency {
    Required(Vec<String>),
    Schema(usize),
}
impl Node {
    fn same_instance(&self) -> Vec<usize> {
        let mut ids = Vec::new();
        for key in ["$ref", "not", "if", "then", "else"] {
            if let Some(id) = self.edges.get(key) {
                ids.push(*id);
            }
        }
        for key in ["allOf", "anyOf", "oneOf"] {
            if let Some(v) = self.lists.get(key) {
                ids.extend(v);
            }
        }
        for dep in self.dependencies.values() {
            if let Dependency::Schema(id) = dep {
                ids.push(*id);
            }
        }
        ids
    }
    fn count_keys(&self) -> bool {
        self.spec.get("minProperties").is_some() || self.spec.get("maxProperties").is_some()
    }
    fn capture(&self) -> bool {
        self.choices.is_some() || self.constant.is_some()
    }
    fn retain_string(&self) -> bool {
        self.pattern.is_some()
            || self.spec.get("format").is_some()
            || self.spec.get("contentEncoding").is_some()
    }
}
/// Immutable, shareable within the owning Lua/Source thread.
pub struct CompiledSchema {
    nodes: Vec<Node>,
    root: usize,
}
impl CompiledSchema {
    pub fn compile(bytes: &[u8]) -> Result<Rc<Self>, String> {
        let value = parse::schema(bytes)?;
        let mut compiler = Compiler {
            document: &value,
            nodes: Vec::new(),
            locations: HashMap::new(),
            depth: 0,
        };
        let root = compiler.node("", &value)?;
        // A reference may recurse through properties/items, but same-instance
        // cycles cannot make progress and must not silently validate true.
        fn visit(
            id: usize,
            nodes: &[Node],
            active: &mut HashSet<usize>,
            heights: &mut HashMap<usize, usize>,
        ) -> Result<usize, String> {
            if let Some(height) = heights.get(&id) {
                return Ok(*height);
            }
            if active.len() >= 256 {
                return Err("schema reference/applicator depth exceeds 256".into());
            }
            if !active.insert(id) {
                return Err("schema has an unguarded reference/composition cycle".into());
            }
            let mut height = 1;
            for child in nodes[id].same_instance() {
                height = height.max(1 + visit(child, nodes, active, heights)?);
            }
            if height > 256 {
                return Err("schema reference/applicator depth exceeds 256".into());
            }
            active.remove(&id);
            heights.insert(id, height);
            Ok(height)
        }
        let mut heights = HashMap::new();
        for id in 0..compiler.nodes.len() {
            visit(id, &compiler.nodes, &mut HashSet::new(), &mut heights)?;
        }
        Ok(Rc::new(Self {
            nodes: compiler.nodes,
            root,
        }))
    }
    fn expand(&self, ids: &[usize]) -> Vec<usize> {
        let mut out = Vec::new();
        let mut pending = ids.to_vec();
        let mut seen = HashSet::new();
        while let Some(id) = pending.pop() {
            if seen.insert(id) {
                out.push(id);
                pending.extend(self.nodes[id].same_instance());
            }
        }
        out
    }
}
struct Compiler<'a> {
    document: &'a Value,
    nodes: Vec<Node>,
    locations: HashMap<String, usize>,
    depth: usize,
}
fn escape(s: &str) -> String {
    s.replace('~', "~0").replace('/', "~1")
}
fn strings(value: &Value, name: &str) -> Result<Vec<String>, String> {
    let values = value
        .as_array()
        .ok_or_else(|| format!("{name} must be an array of strings"))?;
    let out: Vec<String> = values
        .iter()
        .map(|v| {
            v.as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("{name} must contain strings"))
        })
        .collect::<Result<_, _>>()?;
    if out.iter().collect::<HashSet<_>>().len() != out.len() {
        return Err(format!("{name} must contain unique strings"));
    }
    Ok(out)
}
impl Compiler<'_> {
    fn node(&mut self, path: &str, value: &Value) -> Result<usize, String> {
        if let Some(id) = self.locations.get(path) {
            return Ok(*id);
        }
        if self.depth >= 256 {
            return Err("schema compilation depth exceeds 256".into());
        }
        self.depth += 1;
        if !value.is_object() && !value.is_boolean() {
            return Err(format!("schema at #{path} must be an object or boolean"));
        }
        let id = self.nodes.len();
        self.locations.insert(path.to_owned(), id);
        self.nodes.push(Node::default());
        let mut n = Node {
            spec: value.clone(),
            ..Node::default()
        };
        if let Some(object) = value.as_object() {
            for (key, v) in object {
                match key.as_str() {
                    // Only these extensions are annotations. Unknown keywords fail
                    // closed so callers cannot mistake an application hook for an assertion.
                    "$comment"
                    | "title"
                    | "description"
                    | "default"
                    | "examples"
                    | "readOnly"
                    | "writeOnly"
                    | "deprecated"
                    | "contentMediaType"
                    | "x-gateway-authorizable" => {}
                    "$schema" => {
                        let dialect = v
                            .as_str()
                            .ok_or("$schema must be a supported dialect URI")?;
                        if dialect.strip_suffix('#').unwrap_or(dialect)
                            != "https://json-schema.org/draft/2020-12/schema"
                        {
                            return Err(format!("unsupported schema dialect {dialect}"));
                        }
                    }
                    "$id" => {
                        if v.as_str().is_none() {
                            return Err("$id must be a string".into());
                        }
                        if !path.is_empty() {
                            return Err("nested $id scopes are unsupported".into());
                        }
                    }
                    "type" => {
                        let types = if let Some(s) = v.as_str() {
                            vec![s.to_owned()]
                        } else {
                            strings(v, "type")?
                        };
                        if types.is_empty()
                            || types.iter().any(|s| {
                                !matches!(
                                    s.as_str(),
                                    "null"
                                        | "boolean"
                                        | "number"
                                        | "integer"
                                        | "string"
                                        | "array"
                                        | "object"
                                )
                            })
                        {
                            return Err("type must name supported JSON types".into());
                        }
                    }
                    "required" => {
                        n.watch.extend(strings(v, "required")?);
                    }
                    "minLength" | "maxLength" | "minItems" | "maxItems" | "minContains"
                    | "maxContains" | "minProperties" | "maxProperties" => {
                        let count = v
                            .as_number()
                            .and_then(|v| Decimal::parse(&v.to_string()))
                            .and_then(|n| n.as_u64())
                            .ok_or_else(|| {
                                format!("{key} must be a nonnegative integer within u64")
                            })?;
                        n.counts.insert(key.clone(), count);
                    }
                    "uniqueItems" => {
                        if !v.is_boolean() {
                            return Err("uniqueItems must be boolean".into());
                        }
                    }
                    "minimum" | "maximum" | "exclusiveMinimum" | "exclusiveMaximum"
                    | "multipleOf" => {
                        if !v.is_number() {
                            return Err(format!("{key} must be a number"));
                        }
                        let number = Decimal::parse(&v.to_string())
                            .ok_or_else(|| format!("invalid {key}"))?;
                        if key == "multipleOf" && !number.positive() {
                            return Err("multipleOf must be positive".into());
                        }
                        n.numbers.insert(key.clone(), number);
                    }
                    "pattern" => {
                        n.pattern = Some(formats::pattern(
                            v.as_str().ok_or("pattern must be a string")?,
                        )?);
                    }
                    "format" => {
                        if !formats::FORMATS.contains(&v.as_str().ok_or("format must be a string")?)
                        {
                            return Err(format!("unsupported asserted format {v}"));
                        }
                    }
                    "contentEncoding" => {
                        if v.as_str() != Some("base64") {
                            return Err("only base64 contentEncoding is supported".into());
                        }
                    }
                    "enum" => {
                        let a = v.as_array().ok_or("enum must be an array")?;
                        n.choices = Some(a.iter().map(Canon::from_json).collect());
                    }
                    "const" => {
                        n.constant = Some(Canon::from_json(v));
                    }
                    "$defs" | "definitions" | "properties" | "patternProperties" => {
                        for (name, sub) in v
                            .as_object()
                            .ok_or_else(|| format!("{key} must be an object"))?
                        {
                            let subid =
                                self.node(&format!("{path}/{key}/{}", escape(name)), sub)?;
                            if key == "properties" {
                                n.properties.insert(name.clone(), subid);
                            } else if key == "patternProperties" {
                                n.patterns.push((formats::pattern(name)?, subid));
                            }
                        }
                    }
                    "dependencies" | "dependentRequired" | "dependentSchemas" => {
                        for (name, sub) in v
                            .as_object()
                            .ok_or_else(|| format!("{key} must be an object"))?
                        {
                            n.watch.insert(name.clone());
                            let dep = if sub.is_array() && key != "dependentSchemas" {
                                let required = strings(sub, key)?;
                                n.watch.extend(required.iter().cloned());
                                Dependency::Required(required)
                            } else if key != "dependentRequired" {
                                Dependency::Schema(
                                    self.node(&format!("{path}/{key}/{}", escape(name)), sub)?,
                                )
                            } else {
                                return Err("dependentRequired values must be arrays".into());
                            };
                            // Both legacy and new forms may coexist: preserve both.
                            n.dependencies.insert(format!("{key}:{name}"), dep);
                        }
                    }
                    "allOf" | "anyOf" | "oneOf" | "prefixItems" => {
                        let a = v
                            .as_array()
                            .ok_or_else(|| format!("{key} must be an array"))?;
                        if a.is_empty() {
                            return Err(format!("{key} must be nonempty"));
                        }
                        let ids = a
                            .iter()
                            .enumerate()
                            .map(|(i, sub)| self.node(&format!("{path}/{key}/{i}"), sub))
                            .collect::<Result<Vec<_>, _>>()?;
                        n.lists.insert(key.clone(), ids);
                    }
                    "items" if v.is_array() => {
                        if object.contains_key("prefixItems") {
                            return Err("tuple items cannot coexist with prefixItems".into());
                        }
                        let ids = v
                            .as_array()
                            .expect("array")
                            .iter()
                            .enumerate()
                            .map(|(i, sub)| self.node(&format!("{path}/items/{i}"), sub))
                            .collect::<Result<Vec<_>, _>>()?;
                        n.lists.insert("items".into(), ids);
                    }
                    "additionalProperties"
                    | "propertyNames"
                    | "items"
                    | "additionalItems"
                    | "contains"
                    | "not"
                    | "if"
                    | "then"
                    | "else" => {
                        let child = self.node(&format!("{path}/{key}"), v)?;
                        n.edges.insert(key.clone(), child);
                    }
                    "$ref" => {
                        let reference = v.as_str().ok_or("$ref must be a string")?;
                        let fragment = reference
                            .strip_prefix('#')
                            .ok_or("only local $ref is supported")?;
                        let mut decoded = Vec::new();
                        let mut chars = fragment.bytes();
                        while let Some(b) = chars.next() {
                            if b == b'%' {
                                let a = chars.next().ok_or("invalid percent escape in $ref")?;
                                let b = chars.next().ok_or("invalid percent escape in $ref")?;
                                let a = (a as char)
                                    .to_digit(16)
                                    .ok_or("invalid percent escape in $ref")?;
                                let b = (b as char)
                                    .to_digit(16)
                                    .ok_or("invalid percent escape in $ref")?;
                                decoded.push((a * 16 + b) as u8);
                            } else {
                                decoded.push(b);
                            }
                        }
                        let target =
                            String::from_utf8(decoded).map_err(|_| "invalid UTF-8 in $ref")?;
                        let sub = self
                            .document
                            .pointer(&target)
                            .ok_or_else(|| format!("unresolved local $ref {reference}"))?
                            .clone();
                        let child = self.node(&target, &sub)?;
                        n.edges.insert(key.clone(), child);
                    }
                    _ => {
                        return Err(format!(
                            "unsupported executable schema keyword {key} at #{path}"
                        ))
                    }
                }
            }
        }
        self.nodes[id] = n;
        self.depth -= 1;
        Ok(id)
    }
}
