---
marp: true
theme: default
paginate: true
size: 16:9
title: Java 8 Functional Programming & Stream Pipelines in Enterprise Backends
style: |
  section { background: #F5F2EA; color: #1A2233; font-family: 'IBM Plex Sans', Arial, sans-serif; }
  section.dark { background: #0F1626; color: #F5F2EA; }
  section.accent { background: #F28C38; color: #0F1626; }
  h1, h2 { font-family: 'Space Grotesk', Arial, sans-serif; }
  section.dark h1, section.dark h2 { color: #F5F2EA; }
  code, pre { font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 0.72em; }
  .anim { display: inline-block; border: 2px dashed #F28C38; padding: 2px 12px; border-radius: 6px; font-family: monospace; font-size: 0.6em; }
  .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; }
  table { font-size: 0.75em; }
---

<!-- _class: dark lead -->

# Java 8 Functional Programming & Stream Pipelines in Enterprise Backends

<div class="cols">
<div>

**Before · nested loops**

```java
List<Fare> out = new ArrayList<>();
for (Flight fl : flights) {
  for (Fare f : fl.getFares()) {
    if (f.isAvailable() && f.price() < max) {
      out.add(f);
    }
  }
}
out.sort(comparing(Fare::price));
```

</div>
<div>

**After · declarative pipeline**

```java
List<Fare> out = flights.stream()
    .flatMap(fl -> fl.getFares().stream())
    .filter(Fare::isAvailable)
    .filter(f -> f.price() < max)
    .sorted(comparing(Fare::price))
    .collect(toList());
```

</div>
</div>

<!--
NARRATION:
Hey everyone, welcome back to the channel. Today we’re going deep on Java 8 functional programming, and specifically on Stream pipelines as you’d actually use them in an enterprise backend. No toy examples with lists of integers. We’re working with code from an Airline and Banking project: fare filtering, seat maps, daily transaction totals.

Look at the two panels on screen. On the left is how most of us wrote this before Java 8. We want every available fare under a budget, sorted by price. So we create a mutable list, loop over flights, loop again over fares, check a condition, add to the list, and sort at the end. It works, but you have to read every line to figure out what it’s for. Three levels of nesting, one list we keep mutating, and the actual business rule is hidden inside an if statement.

Now look at the right. Same result. We flatten flights into fares, keep the available ones, keep the ones under budget, sort by price, and collect. You read it top to bottom and it says exactly what the business wants. That’s the shift from imperative to declarative: you describe what you want, not how to loop.

In this episode we’ll cover the four functional interfaces you’ll use every day, what the JVM actually does with a lambda, how a stream pipeline runs element by element, advanced collectors for banking reports, the parallel stream trap that takes down production services, and how to use Optional properly. Let’s get into it.
-->

---

## The core four functional interfaces

| Interface | Method | Lambda syntax | In our project |
|---|---|---|---|
| `Predicate<T>` | `boolean test(T)` | `s -> s.isAvailable()` | Seat gate: is it bookable? |
| `Function<T,R>` | `R apply(T)` | `s -> new SeatDto(s)` | Entity → DTO mapping |
| `Consumer<T>` | `void accept(T)` | `t -> audit.log(t)` | Audit-trail side effect |
| `Supplier<T>` | `T get()` | `() -> new ArrayList<>()` | Lazy default or factory |

**Shape to remember:** *test* answers yes/no, *apply* transforms, *accept* consumes, *get* produces.

<!--
NARRATION:
Before we touch streams, you need four interfaces in your head, because every stream operation takes one of them as its argument.

First, Predicate of T. One method, test, takes a T and returns a boolean. Think of it as a gate. In our airline code, “is this seat available?” is a predicate. The lambda is just s arrow s dot isAvailable.

Second, Function of T comma R. Its method is apply: takes a T, gives back an R. That’s your transformer. Every time we turn a Seat entity into a SeatDto for the API response, that’s a Function. It’s what map expects.

Third, Consumer of T. The accept method takes a T and returns nothing, so it exists purely for side effects. Writing a transaction to the audit log is a Consumer. You’ll see it in forEach and in peek.

And fourth, Supplier of T. No input at all, just get, which hands you a T. It’s perfect for lazy defaults and factories. You’ll see it in orElseGet, and in collectors that need a fresh container, like “give me a new ArrayList.”

Here’s the trick to remember them, at the bottom of the slide. Test says yes or no. Apply transforms. Accept consumes. Get produces. If you can tell which of those four jobs a lambda is doing, you know which interface the compiler is targeting. And there are cousins, like BiFunction, UnaryOperator, and the primitive versions like IntPredicate that avoid boxing, but they’re all variations on these four.
-->

---

<!-- _class: dark -->

## Under the hood: how lambdas compile

<div class="cols">
<div>

**Legacy · anonymous inner class**

```java
Predicate<Seat> p = new Predicate<Seat>() {
  public boolean test(Seat s) {
    return s.isAvailable();
  }
};
```

- Compiles to its own `SeatFilter$1.class`
- Every such class is loaded and verified
- Always captures the outer `this`

</div>
<div>

**Java 8 · lambda + invokedynamic**

```java
Predicate<Seat> p = Seat::isAvailable;

// javap -c
invokedynamic #7, 0
  // test:()Ljava/util/function/Predicate;
```

- No extra .class file in your JAR
- Linked once by `LambdaMetafactory`
- Non-capturing: one cached instance

</div>
</div>

`javac` → `invokedynamic` → `LambdaMetafactory` → `CallSite linked` → **later calls: direct**

<!--
NARRATION:
So what actually happens when you write a lambda? A lot of developers assume it’s just syntactic sugar for an anonymous inner class. It isn’t, and the difference matters in a big service.

On the left is the old way. When javac sees an anonymous Predicate, it generates a whole separate class file, something like SeatFilter dollar one dot class. Have a few hundred of these across a codebase and that’s a few hundred classes the JVM has to load and verify. And an anonymous inner class created in an instance method always holds a reference to the enclosing object, the outer this, even if you never use it. That’s a classic memory-leak path when callbacks outlive their owners.

On the right is Java 8. The body of the lambda becomes a private method inside your own class. Where you use it, javac emits a single invokedynamic instruction. You can see it in javap: invokedynamic, and a comment saying it produces a Predicate.

Follow the strip at the bottom. The first time that instruction executes, the JVM calls a bootstrap method, LambdaMetafactory, which spins up the implementation at runtime and links the call site. After that, the call site is linked, and every later call goes straight through, with no bootstrap cost.

And here’s the bonus. If your lambda doesn’t capture any variables, like Seat colon colon isAvailable, the JVM can hand back the same instance every time. No allocation per call. So lambdas aren’t just shorter to write. They leave fewer classes in your JAR and give the JIT more room to optimise.
-->

---

## Anatomy of a stream pipeline

<span class="anim">[ANIMATION: Step-by-Step Highlight]</span> Elements travel one at a time. Nothing moves until `collect()` pulls.

| Source `stream()` | Intermediate `filter(..)` | Intermediate `map(..)` | Intermediate `sorted(..)` | Terminal `collect(..)` |
|---|---|---|---|---|
| The seat list, not yet read | Lazy · stateless gate | Lazy · stateless transform | Lazy · stateful barrier | Eager · pulls the data |
| ① Seat 12A · $180 | ② 12A · pass | ③ SeatDto 12A | ④ 12A · waits | ⑫ list[1] = 12A |
| ⑤ Seat 12B · sold | ⑥ 12B · dropped | | | |
| ⑦ Seat 14C · $140 | ⑧ 14C · pass | ⑨ SeatDto 14C | ⑩ 14C · waits | ⑪ list[0] = 14C |

Stateless steps pass each seat straight through. `sorted()` holds everything until the source is drained, then releases by price.

<!--
NARRATION:
[ANIMATION: Step-by-Step Highlight. Each seat pill appears one at a time, moving left to right through the gates, before the terminal collector pops them into the list.]

This is the most important mental model in the whole video, so let’s slow down.

A stream pipeline has three parts. A source, here our list of seats. Zero or more intermediate operations: filter, map, sorted. And exactly one terminal operation, collect. Here’s the key: intermediate operations are lazy. Calling filter doesn’t filter anything. It just adds a stage. Nothing happens until the terminal operation starts pulling.

Watch the animation. Seat 12A comes out of the source. It goes through the filter gate, it’s available, so it passes. It goes straight into map and becomes a SeatDto. Notice it didn’t wait for the other seats. Streams process one element at a time, vertically, through every stateless stage.

Then it hits sorted, and it waits. Sorted is a stateful barrier. It can’t emit anything until it has seen every element, because the cheapest seat might be the last one.

Now seat 12B. It’s sold, so the filter drops it right there. It never reaches map, and no DTO is built for it. That’s free performance.

Seat 14C passes the filter, gets mapped, and joins 12A at the barrier. Now the source is empty, so sorted releases them in price order: 14C at 140 lands in index zero, then 12A at 180 in index one.

So two takeaways. Order your filters before your maps, so you don’t transform data you’ll throw away. And be aware that sorted, distinct and similar operations buffer everything.
-->

---

<!-- _class: dark -->

## Visual trace: available seats to DTOs

<span class="anim">[ANIMATION: Step-by-Step Highlight]</span>

<div class="cols">
<div>

```java
List<SeatDto> seats = flight.getSeats()
    .stream()
    .filter(Seat::isAvailable)
    .filter(s -> s.getCabin() == ECONOMY)
    .map(SeatMapper::toDto)
    .collect(Collectors.toList());

// SeatMapper
static SeatDto toDto(Seat s) {
  return new SeatDto(s.getNumber(),
      s.getCabin(), s.getPrice());
}
```

</div>
<div>

1. **Input** · 12A ECO · 12B ECO sold · 2C BUS · 14C ECO
2. **Gate 1** `filter(Seat::isAvailable)` · 12A, 2C, 14C pass · 12B dropped (sold)
3. **Gate 2** `filter(cabin == ECONOMY)` · 12A, 14C pass · 2C dropped (business)
4. **Transform** `map(SeatMapper::toDto)` · SeatDto(12A), SeatDto(14C)
5. **Terminal** `collect(toList())` · `List<SeatDto>` of 2 → JSON response

</div>
</div>

<!--
NARRATION:
[ANIMATION: Step-by-Step Highlight. Reveal the trace boxes one at a time on the right, in sync with highlighting each line of code on the left, so each seat visibly passes or fails a gate before the collector.]

Let’s trace this with real code from the project. This is the seat-map endpoint. A customer opens the booking page and we have to return the available economy seats as DTOs.

On the left is the pipeline. We get the flight’s seats, open a stream, filter on isAvailable, filter on cabin equals economy, map each Seat entity through SeatMapper toDto, and collect to a list.

Now the right side. Our input is four seats: 12A economy, 12B economy but already sold, 2C in business, and 14C economy.

Gate one, isAvailable. 12A passes, 2C passes, 14C passes. 12B is sold, so it’s dropped right here, and it never touches the next line of code.

Gate two, the cabin check. 12A and 14C are economy and they go through. 2C is business class, so it’s dropped.

Now the transform. Only two seats are left, so only two DTOs are built. That matters with JPA, because if toDto touches a lazy relationship, every element that reaches map can trigger a database hit. Filtering first means we only pay for the seats we actually return.

And finally the terminal operation, collect, gives us a list of two SeatDtos, which Jackson serialises into the JSON response.

One reminder from the last slide: even though I’m showing this gate by gate, at runtime each seat runs through the whole chain before the next seat starts. The boxes on the right show what survives each gate in total.
-->

---

## Banking: daily totals by currency

<div class="cols">
<div>

```java
Map<Currency, BigDecimal> totals = txns.stream()
    .filter(t -> t.getDate().equals(today))
    .collect(Collectors.groupingBy(
        Transaction::getCurrency,
        Collectors.reducing(
            BigDecimal.ZERO,
            Transaction::getAmount,
            BigDecimal::add)));
```

</div>
<div>

**Sample output**

| Key | Total |
|---|---:|
| USD | [4,250.00] |
| EUR | [1,180.50] |
| INR | [92,400.00] |

- **groupingBy** picks the bucket: one per currency
- **reducing** folds each bucket: identity, mapper, combiner
- **BigDecimal::add** keeps cents exact, unlike summingDouble

</div>
</div>

<!--
NARRATION:
Let’s move from the airline side to banking, because this is where collectors really earn their keep.

The requirement: at end of day, give operations the total transaction amount per currency. Old school, you’d create a HashMap, loop over every transaction, check whether the currency key exists, get the running total, add, and put it back. Lots of ceremony and lots of places to make a mistake.

Here’s the stream version. We filter to today’s transactions, then collect with groupingBy. groupingBy takes a classifier, Transaction getCurrency, and that decides which bucket each transaction lands in. One bucket for USD, one for EUR, one for INR.

But by default groupingBy gives you a list of transactions per bucket, and we don’t want lists. We want a single total. So we pass a downstream collector, Collectors dot reducing. It takes three things. An identity, BigDecimal ZERO, which is where every bucket starts. A mapper, getAmount, to pull the amount out of each transaction. And a combiner, BigDecimal add, to fold them together.

The result, on the right, is a map from currency to total. These figures are placeholders, so plug in your own sample data.

Now, why not just use summingDouble? It would be shorter. But this is money. Doubles are binary floating point, and amounts like zero point one can’t be represented exactly, so rounding errors creep into your ledger. BigDecimal with add keeps every cent exact. In a banking backend, that isn’t an optimisation. It’s a correctness requirement, and your auditors will thank you.
-->

---

<!-- _class: dark -->

## The parallel stream trap

<span class="anim">[ANIMATION: Step-by-Step Highlight]</span> Blocking I/O inside `parallelStream()` starves the shared pool

<div class="cols">
<div>

**Looks innocent**

```java
List<Fare> fares = flightIds
    .parallelStream()
    .map(id -> pricingClient.fetch(id))
    .collect(toList());
// fetch() blocks on HTTP I/O
```

**The fix · a dedicated I/O pool**

```java
ExecutorService io = newFixedThreadPool(50);
flightIds.stream()
    .map(id -> supplyAsync(
        () -> client.fetch(id), io))
    .collect(toList());
```

</div>
<div>

**commonPool() · 7 workers on 8 cores**

1. worker-1 · idle → BLOCKED in fetch(AI101)
2. worker-2 · idle → BLOCKED in fetch(AI102)
3. worker-3 · idle → BLOCKED in fetch(AI103)
4. worker-4 · idle → BLOCKED in fetch(AI104)
5. worker-5 · idle → BLOCKED in fetch(AI105)
6. worker-6 · idle → BLOCKED in fetch(AI106)
7. worker-7 · idle → BLOCKED in fetch(AI107)

**Queue backs up:** every other parallel stream and default `supplyAsync()` in the JVM now waits

</div>
</div>

<!--
NARRATION:
[ANIMATION: Step-by-Step Highlight. Each idle worker turns into a BLOCKED worker one by one as fetch calls enter the pool, then the queue warning pops in once all seven are stuck.]

This one has taken down real production services, so pay attention.

Look at the code in the top left. We have a list of flight IDs and we need a price for each one from an external pricing API. Someone thinks, “that’s slow, let’s just make it parallel,” and swaps stream for parallelStream. One word. Looks innocent.

Here’s the problem. Parallel streams don’t get their own threads. They run on ForkJoinPool dot commonPool, a single pool shared by the entire JVM. By default it has one fewer thread than you have cores, so seven workers on an eight-core box.

Watch the right side. The first fetch call grabs worker one, and it blocks, sitting there waiting on the network. Worker two, blocked. Three, four, five, six, seven. Every worker in the shared pool is now parked on HTTP I/O, doing no CPU work at all.

And now the real damage. That pool is shared. Every other parallel stream in your application, and every CompletableFuture supplyAsync that didn’t specify an executor, is now stuck in the queue behind your slow pricing calls. A completely unrelated report endpoint suddenly times out, and your thread dump is full of ForkJoinPool workers waiting on sockets.

The fix is at the bottom left. Keep parallel streams for CPU-bound work on in-memory data. For blocking I/O, create a dedicated executor sized for I/O, and use CompletableFuture supplyAsync with that executor passed in explicitly. Then join the futures. Your slow calls are now isolated, and the common pool stays free for the work it was designed for. Size that pool from load testing, not from a slide.
-->

---

## Null safety with Optional&lt;T&gt;

<div class="cols">
<div>

**Anti-patterns**

```java
// Don't: get() with no check
Fare f = fareRepo.findById(id).get();

// Don't: Optional as a field
class Booking {
  private Optional<Seat> seat;
}
```

- `get()` is a NoSuchElementException in disguise
- Optional isn't Serializable: breaks JPA and caches

</div>
<div>

**Industrial chaining**

```java
String gate = bookingRepo.findById(ref)
    .map(Booking::getFlight)
    .map(Flight::getGate)
    .orElseThrow(() ->
        new BookingNotFoundException(ref));
```

- Each `map()` step is skipped safely when empty
- Fails loudly with a domain exception

</div>
</div>

**Rule of thumb:** return Optional from finders. Never use it for fields or method parameters.

<!--
NARRATION:
Let’s talk about Optional, because it’s one of the most misused features in Java 8.

Optional was designed for one job: to be a return type that says “this might not have a value,” so the caller is forced to think about the empty case. That’s it. Most of the misuse comes from treating it as a general-purpose null wrapper.

Look at the left. Anti-pattern number one: calling get without checking. findById returns an Optional, and we immediately call get. If the fare isn’t there, you get a NoSuchElementException. That’s just a NullPointerException with a different name. And if you write “if isPresent then get,” you’ve rebuilt a null check with more typing.

Anti-pattern number two: Optional as a field. Optional isn’t Serializable, so it causes trouble with JPA entities, session replication and distributed caches. And it adds an extra object to every Booking. For fields, use a plain nullable reference and expose an Optional from the getter if you want to.

Now the right side. This is how it looks in a mature codebase. We look up the booking, map to its flight, map to the gate, and if anything along that chain is empty, we throw a BookingNotFoundException with the reference. No nested null checks and no get. Each map step simply skips when the value is empty.

And the failure is explicit. With a domain exception your controller advice can turn it into a clean 404 instead of a mystery 500.

So here’s the rule of thumb on the bottom line. Return Optional from finders and lookups. Don’t use it for fields or method parameters.
-->

---

<!-- _class: dark -->

## Live refactor: before and after

| Metric | Imperative loops | Stream pipeline |
|---|---|---|
| Lines of code | 9 | 6 |
| Levels of nesting | 3 | 0 |
| Collections mutated by hand | 1 | 0 |
| Reads as | How to loop | What the business wants |
| Immutability | `out.add()`, `out.sort()` in place | Collector builds the result once |
| Parallel-ready | No: shared mutable list | Yes: stateless steps |

*Counted on the fare filter from the opening slide.*

<!--
NARRATION:
Let’s close the loop on the fare filter from the very first slide, and put some numbers on it.

Lines of code: nine down to six. That isn’t the headline, though. Fewer lines is nice, but it isn’t the point.

Nesting depth: three levels down to zero. The imperative version had a for inside a for inside an if. The stream version is a flat chain. Your eyes go straight down. That’s the metric that really predicts how long a code review takes and how many bugs hide in a method.

Collections mutated by hand: one down to zero. In the old version we created an ArrayList and then added to it and sorted it in place. In the stream version, the collector builds the result once at the end. No one else ever sees a half-built list.

Now the table. Readability: the loop reads as instructions for how to loop, and the pipeline reads as the business rule. Available fares, under budget, cheapest first.

Immutability: the loop mutates state all the way through. The pipeline has no shared mutable state in our code. And if you need a truly unmodifiable result, wrap it with Collections unmodifiableList, or in Java 10 and later use toUnmodifiableList.

And because every step is stateless, the pipeline is structurally ready for parallel execution. With the shared ArrayList, adding threads would mean adding locks. Just remember the last-but-one slide: parallel is only for CPU-bound work.

These numbers come from our slide-one example, so try the same before-and-after count on one of your own methods.
-->

---

<!-- _class: accent -->

## Key takeaways

1. Think in pipelines: filter early, map late, collect once.
2. Lambdas link through invokedynamic, not extra inner classes.
3. Never block inside `parallelStream()`; give I/O its own executor.
4. Optional is a return type: chain `map()`, end with `orElseThrow()`.

**Next episode → CompletableFuture: async fare lookups without starving the common pool**

<!--
NARRATION:
Alright, let’s wrap up with four things I want you to take back to your codebase.

One. Think in pipelines. Filter early so you don’t do work on data you’ll throw away, map late so you only transform what survives, and collect once at the end.

Two. Lambdas aren’t anonymous classes in disguise. They’re linked at runtime through invokedynamic and LambdaMetafactory, so you get fewer classes, and non-capturing lambdas don’t allocate per call. Write them freely.

Three, and if you only remember one thing, make it this one. Never put blocking I/O inside a parallel stream. It runs on the shared common pool, and you’ll starve every other part of the JVM that depends on it. Give I/O its own executor.

Four. Optional is a return type. Chain it with map, and finish with orElseThrow or orElseGet. Never call a bare get, and never make it a field.

Now, at the bottom of the slide you can see where we’re going next. In the next episode, we take that dedicated executor from the parallel stream slide and go all in on CompletableFuture. We’ll fan out fare lookups to several pricing services at the same time, combine the results, handle timeouts and failures, and never block the common pool. It’s the natural sequel to everything we covered today.

If this helped, hit like and subscribe so you catch that one. And drop a comment with the worst stream or Optional code you’ve seen in production. I’ll feature a few in the next video. See you there.
-->
