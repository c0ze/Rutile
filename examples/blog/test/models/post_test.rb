require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "title is required and at most 200 characters" do
    post = Post.new(user: users(:alice), title: "")
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"

    post.title = "x" * 201
    assert_not post.valid?
    assert_includes post.errors[:title], "is too long (maximum is 200 characters)"
  end

  test "an unknown status is a validation error, not an exception" do
    post = Post.new(user: users(:alice), title: "Hi", status: "archived")
    assert_not post.valid?
    assert_includes post.errors[:status], "is not included in the list"
  end

  test "publishing stamps published_at once" do
    post = posts(:draft)
    assert_nil post.published_at

    post.update!(status: :published)
    stamped = post.reload.published_at
    assert_not_nil stamped

    post.update!(title: "Edited")
    assert_equal stamped, post.reload.published_at
  end

  test "drafts never get published_at" do
    post = Post.create!(user: users(:bob), title: "Still a draft")
    assert_nil post.published_at
  end

  test "visible.recent lists published posts newest first" do
    assert_equal [posts(:published_new), posts(:published_old)], Post.visible.recent.to_a
  end

  test "created_since, inherited from ApplicationRecord, filters by creation time" do
    recent = Post.created_since(2.days.ago)
    assert_includes recent, posts(:published_new)
    assert_not_includes recent, posts(:published_old)
  end
end
