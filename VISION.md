# Vision: The Invisible AI Coworker

## The Problem

Current AI coding tools work on a **command → response** model. You stop what you're doing, write a prompt, wait for the AI to respond, review, and iterate. This breaks your flow and creates an artificial loop between you and AI.

What if AI just *helped* — asynchronously, in the background, without you having to explicitly command it?

## The Vision

An editor where AI works alongside you as an **invisible coworker**, not a tool you summon. You work naturally, AI watches your context, infers what you need, and acts when you give it permission.

### Core Concepts

**1. Two Contexts**
- **Big picture:** What you're building overall (project goals, architecture)
- **Current focus:** What you're working on right now (current file, recent edits)

These two contexts tell AI where you're headed and what help you need.

**2. Breadcrumb Stack = Permission Signal**
When you open a file, it enters the breadcrumb stack. The deeper a file is in the stack (further from your current position), the more permission you've implicitly given AI to work on it.

- **Current file:** Locked — AI can suggest, but won't auto-edit
- **Files one level back:** AI can propose changes, waits for approval
- **Files deep in stack:** Full autonomy — AI can implement, will notify when done

You "unlock" a file simply by returning to it. Your attention *is* your permission.

**3. Zap Views — Focus as a Sliding Window**
When you switch tasks, you see both files: the one you're leaving (shrinking) and the one you're entering (growing). The window sizes represent your focus. As you scroll up in a file, you see more context — this is how AI knows how much attention you've given it.

**4. The Feedback Loop**
- You write where you need help (TODOs, questions, comments)
- AI reads the context, infers intent, acts asynchronously
- When you return, you see what AI did and edit as needed
- Your edits update the context, AI learns and adjusts

This isn't "AI does X for me" — it's a **back-and-forth** where you design/spec and AI implements/revises.

## The Workflow

1. **Open the editor** → AI suggests tasks based on project context
2. **Pick a task** → File opens in a zap view
3. **Work and switch** → As you move between files, AI infers intent
4. **Breadcrumb distance grows** → AI gains permission to act
5. **AI works in background** → You get notified when done
6. **Return and review** → Edit, approve, iterate

## Why This Works

You're already doing this mental tracking: "I've been away from that file, I should probably check it." The breadcrumb stack makes that implicit permission *visible* and *actionable* for AI.

You don't need to craft perfect prompts. You just write where the work needs to happen, and AI uses your context to infer what you want.

## Not Just Code

This isn't just for code. The same workflow works for:
- Writing prompts and queries
- Creating documentation
- Running calculations
- Any task where AI can help and you can review

The file format doesn't matter. What matters is the **asynchronous collaboration** between human intent and AI action.

## The Goal

Create flow state with AI. You open the terminal, get AI-suggested tasks, work through them naturally, and AI handles background work. When you return to a file, it's done or improved — you just review and iterate.

Instead of AI as an **input-output device**, it's an **invisible helper** that sees what you see, knows what you've done, and acts when you give it room to work.




## Layout



docs/a_file.md (1:5)
  1
  2
  3
  4
  5
docs/SomeFile.txt (20:25)
 20
 21
 22
23Cursor 
 24
 25
docs/a_file.md (6:10)
  6
  7
  8
  9
 10