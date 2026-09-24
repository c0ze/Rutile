require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "body is required" do
    comment = Comment.new(post: posts(:published_old), user: users(:bob))
    assert_not comment.valid?
    assert_includes comment.errors[:body], "can't be blank"
  end

  test "creating a comment bumps the post's comments_count" do
    post = posts(:published_new)
    assert_difference -> { post.reload.comments_count }, 1 do
      Comment.create!(post: post, user: users(:alice), body: "Agreed")
    end
  end

  test "posts must be published before they take comments" do
    comment = Comment.new(post: posts(:draft), user: users(:bob), body: "Early")
    assert_not comment.valid?
    assert_includes comment.errors[:post], "must be published"
  end
end
