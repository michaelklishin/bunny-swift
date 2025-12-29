# Instructions for AI Agents

## Overview

This is a Swift 6+ [client library](https://www.rabbitmq.com/client-libraries) for RabbitMQ heavily
inspired by Bunny (Ruby), Pika (Python), amqprs (Rust) and the .NET RabbitMQ client 7.x.

## Repository Layout

 * `Sources`: contains the Swift source code
 * `Tests`: contains tests
 * `tutorials`: a port of [executable RabbitMQ tutorials](http://github.com/rabbitmq/rabbitmq-tutorials)

## Code Style

 * Target Swift 6, iOS 18, iPad OS 18, macOS Sonoma
 * At the end of each task, format the entire codebase using [`swift-format`](https://github.com/swiftlang/swift-format)

## Tests

Tests should be descriptive and easy to read. Use property-based tests for edge cases
in addition to unit tests.

## Comments

 * Only add important comments that express the non-obvious intent, both in tests and in the implementation
 * Keep the comments short
 * Pay attention to the grammar of your comments, including punctuation, full stops, articles, and so on
 * Do not add `()` to function names or references: use `VersionVector.decode` and not `VersionVector.decode()`

## Git Instructions

 * Never add yourself to the list of commit co-authors

## Style Guide

 * Never add full stops to Markdown list items

## After Completing a Task

After completing a task, look very carefully for gaps in the implementation, the test coverage,
missed opportunities to use modern Swift idioms, meaningful optimizations on the common code paths,
and more ways to lean on the Swift's expressive type system for additional safety.

Reducing duplication is good unless it makes the codebase more complex.

"There's nothing meaningful to improve" is an acceptable answer.
